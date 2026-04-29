"""
src/ffmpeg_processor/app.py

Lambda pesada: transcodifica videos a 720p y 480p con FFmpeg y actualiza DynamoDB.

── Cadena de eventos ────────────────────────────────────────────────────────
  S3 PutObject (uploads/*.mp4)
    └─► SNS topic (video-ingest-fanout)   [raw_message_delivery = true]
          └─► SQS (ffmpeg-processing)
                └─► esta Lambda           [ESM batch_size = 1, concurrency = 5]

── Por qué /tmp y no Presigned URL ─────────────────────────────────────────
  La Lambda está en VPC con Gateway VPC Endpoint para S3.
  boto3 usa ese endpoint (sin internet) → download_file funciona.
  FFmpeg haría TCP a la URL pública → DNS falla sin NAT Gateway.
  Solución: boto3 descarga a /tmp, FFmpeg lee desde disco local.

── Variables de entorno requeridas ─────────────────────────────────────────
  DYNAMODB_TABLE    nombre exacto de la tabla DynamoDB
  PROCESSED_BUCKET  nombre del bucket S3 de output
  ENVIRONMENT       dev | prod
  LOG_LEVEL         DEBUG | INFO | WARNING | ERROR
  FFMPEG_PRESET     ultrafast (dev) | medium (prod)
"""

from __future__ import annotations

import json
import logging
import os
import subprocess
import tempfile
import urllib.parse
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

import boto3
from botocore.exceptions import ClientError

# ── Logging ───────────────────────────────────────────────────────────────────
_LOG_LEVEL: str = os.environ.get("LOG_LEVEL", "INFO").upper()
logging.basicConfig(
    format="%(asctime)s [%(levelname)s] %(name)s - %(message)s",
    level=_LOG_LEVEL,
)
logger = logging.getLogger(__name__)
logger.setLevel(_LOG_LEVEL)

# ── Variables de entorno ──────────────────────────────────────────────────────
DYNAMODB_TABLE: str   = os.environ["DYNAMODB_TABLE"]
PROCESSED_BUCKET: str = os.environ["PROCESSED_BUCKET"]
ENVIRONMENT: str      = os.environ.get("ENVIRONMENT", "dev")
FFMPEG_PRESET: str    = os.environ.get("FFMPEG_PRESET", "ultrafast")
FFMPEG_BIN: str       = "/opt/bin/ffmpeg"

# ── Clientes AWS — module-level para reutilización en warm starts ─────────────
_s3       = boto3.client("s3")
_dynamodb = boto3.resource("dynamodb")
_table    = _dynamodb.Table(DYNAMODB_TABLE)

_STATUS_PROCESSING = "PROCESSING"
_STATUS_DONE       = "DONE"
_STATUS_FAILED     = "FAILED"


# ── Modelos ───────────────────────────────────────────────────────────────────

@dataclass(frozen=True)
class S3Object:
    """Referencia mínima a un objeto S3 extraída del evento SQS."""
    bucket_name: str
    object_key: str   # ya decodificado de URL
    event_time: str   # ISO 8601 — range key en DynamoDB


@dataclass(frozen=True)
class TranscodeOutput:
    """Paths locales y keys S3 de los dos outputs de FFmpeg."""
    local_720p: Path
    local_480p: Path
    key_720p: str
    key_480p: str


# ── Parser — autónomo, idéntico al de metadata_extractor ─────────────────────

def parse_s3_object_from_sqs_record(record: dict[str, Any]) -> S3Object:
    """
    Extrae la referencia al objeto S3 del body de un SQS Record.

    Detecta automáticamente raw_message_delivery = true/false:
      - true:  body ES el evento S3 directamente.
      - false: body tiene body["Message"] con el evento S3 como string JSON.

    Raises:
        ValueError: Si es un test event de S3 o no contiene Records.
        json.JSONDecodeError: Si el body no es JSON válido.
    """
    body: dict[str, Any] = json.loads(record["body"])

    # Desenvolver sobre SNS si existe (raw_message_delivery = false)
    if "Message" in body and isinstance(body["Message"], str):
        s3_event: dict[str, Any] = json.loads(body["Message"])
    else:
        s3_event = body

    if s3_event.get("Event") == "s3:TestEvent":
        raise ValueError("Test event de S3 — ignorado.")

    s3_records: list[dict[str, Any]] = s3_event.get("Records", [])
    if not s3_records:
        raise ValueError(f"El evento no contiene Records de S3: {s3_event}")

    s3_record: dict[str, Any] = s3_records[0]
    s3_info = s3_record["s3"]
    decoded_key: str = urllib.parse.unquote_plus(s3_info["object"]["key"])

    return S3Object(
        bucket_name=s3_info["bucket"]["name"],
        object_key=decoded_key,
        event_time=s3_record["eventTime"],
    )


def derive_video_id(object_key: str) -> str:
    """
    Genera el video_id (hash_key de DynamoDB) a partir del object_key.

    ALGORITMO IDÉNTICO al de metadata_extractor — no modificar sin
    actualizar ambas Lambdas simultáneamente. Si difieren, cada Lambda
    escribe en una fila distinta y el join de Notification nunca se cumple.

        "uploads/carpeta/mi-video.mp4"
          1. strip "uploads/"  → "carpeta/mi-video.mp4"
          2. strip extensión   → "carpeta/mi-video"
          3. "/" → "-"         → "carpeta-mi-video"
    """
    key = object_key
    if key.startswith("uploads/"):
        key = key[len("uploads/"):]
    if "." in key:
        key = key.rsplit(".", 1)[0]
    return key.replace("/", "-")


# ── DynamoDB — escrituras de estado ──────────────────────────────────────────

def _mark_processing(video_id: str, uploaded_at: str) -> None:
    """
    Escribe transcoding_status = PROCESSING antes de descargar el video.

    Early write: si la Lambda muere durante la descarga o transcodificación,
    el estado queda en PROCESSING — señal de fallo para el operador.
    update_item no toca los campos escritos por metadata_extractor.
    """
    now_iso: str = datetime.now(timezone.utc).isoformat()
    logger.info("DynamoDB: PROCESSING — video_id=%s", video_id)
    _table.update_item(
        Key={"video_id": video_id, "uploaded_at": uploaded_at},
        UpdateExpression=(
            "SET transcoding_status     = :status, "
            "    transcoding_started_at = :ts"
        ),
        ExpressionAttributeValues={":status": _STATUS_PROCESSING, ":ts": now_iso},
    )


def _mark_done(
    video_id: str,
    uploaded_at: str,
    key_720p: str,
    key_480p: str,
) -> None:
    """
    Escribe transcoding_status = DONE con las keys de output en S3.

    La Lambda Notification lee este campo del DynamoDB Stream para
    verificar si ambos procesos (metadata + transcoding) terminaron.
    """
    now_iso: str = datetime.now(timezone.utc).isoformat()
    logger.info("DynamoDB: DONE — video_id=%s", video_id)
    _table.update_item(
        Key={"video_id": video_id, "uploaded_at": uploaded_at},
        UpdateExpression=(
            "SET transcoding_status       = :status, "
            "    output_720p_key          = :k720,   "
            "    output_480p_key          = :k480,   "
            "    transcoding_completed_at = :ts"
        ),
        ExpressionAttributeValues={
            ":status": _STATUS_DONE,
            ":k720":   key_720p,
            ":k480":   key_480p,
            ":ts":     now_iso,
        },
    )


def _mark_failed(video_id: str, uploaded_at: str, error_message: str) -> None:
    """
    Escribe transcoding_status = FAILED con el mensaje de error.

    Llamado antes del re-raise para que SQS pueda reintentar el mensaje.
    El re-raise en _process_single_record es intencional — no eliminarlo.
    """
    now_iso: str = datetime.now(timezone.utc).isoformat()
    logger.error("DynamoDB: FAILED — video_id=%s", video_id)
    try:
        _table.update_item(
            Key={"video_id": video_id, "uploaded_at": uploaded_at},
            UpdateExpression=(
                "SET transcoding_status    = :status, "
                "    transcoding_error     = :err,    "
                "    transcoding_failed_at = :ts"
            ),
            ExpressionAttributeValues={
                ":status": _STATUS_FAILED,
                ":err":    error_message[:1000],
                ":ts":     now_iso,
            },
        )
    except ClientError as exc:
        # No enmascarar el error original
        logger.error("No se pudo escribir FAILED en DynamoDB: %s", exc)


# ── S3 — transferencia ────────────────────────────────────────────────────────

def _download_video(bucket: str, key: str, dest: Path) -> None:
    """Descarga el video crudo de S3 raw a /tmp usando el VPC endpoint."""
    logger.info("Descargando s3://%s/%s → %s", bucket, key, dest)
    _s3.download_file(bucket, key, str(dest))
    logger.debug("Descarga completa — %.1f MB", dest.stat().st_size / (1024 * 1024))


def _upload_output(local_path: Path, s3_key: str) -> None:
    """Sube un archivo transcodificado al bucket processed."""
    logger.info("Subiendo %s → s3://%s/%s", local_path.name, PROCESSED_BUCKET, s3_key)
    _s3.upload_file(
        str(local_path),
        PROCESSED_BUCKET,
        s3_key,
        ExtraArgs={"ContentType": "video/mp4"},
    )
    logger.debug("Upload completo — %s", s3_key)


# ── FFmpeg ────────────────────────────────────────────────────────────────────

def _transcode(input_path: Path, tmp_dir: Path, video_id: str) -> TranscodeOutput:
    """
    Produce 720p y 480p con FFmpeg desde un archivo local.

    Parámetros notables:
      scale=W:-2   ancho fijo, alto calculado automáticamente (par, necesario para H.264)
      -crf 23      calidad constante (0=lossless, 51=peor, 23=default razonable)
      +faststart   mueve el moov atom al inicio del MP4 — esencial para streaming HTTP
      -y           sobreescribir output sin preguntar (idempotente en reintentos)

    Raises:
        subprocess.CalledProcessError: FFmpeg terminó con código != 0.
        FileNotFoundError: Binario FFmpeg no encontrado en /opt/bin/ffmpeg.
    """
    resolutions: list[tuple[str, str, Path]] = [
        ("1280:-2", "720p",  tmp_dir / f"{video_id}_720p.mp4"),
        ("854:-2",  "480p",  tmp_dir / f"{video_id}_480p.mp4"),
    ]

    outputs: dict[str, Path] = {}

    for scale, label, output_path in resolutions:
        logger.info(
            "FFmpeg: %s — input=%s preset=%s",
            label, input_path.name, FFMPEG_PRESET,
        )

        result = subprocess.run(
            [
                FFMPEG_BIN,
                "-i",        str(input_path),
                "-vf",       f"scale={scale}",
                "-c:v",      "libx264",
                "-preset",   FFMPEG_PRESET,
                "-crf",      "23",
                "-c:a",      "aac",
                "-b:a",      "128k",
                "-movflags", "+faststart",
                "-y",
                str(output_path),
            ],
            capture_output=True,
            text=True,
            check=True,  # CalledProcessError si FFmpeg retorna != 0
        )

        if result.stderr:
            logger.debug("FFmpeg stderr (%s): ...%s", label, result.stderr[-800:])

        logger.info(
            "FFmpeg OK — %s (%.1f MB)",
            label,
            output_path.stat().st_size / (1024 * 1024),
        )
        outputs[label] = output_path

    return TranscodeOutput(
        local_720p=outputs["720p"],
        local_480p=outputs["480p"],
        key_720p=f"processed/{video_id}_720p.mp4",
        key_480p=f"processed/{video_id}_480p.mp4",
    )


# ── Procesamiento de un record ────────────────────────────────────────────────

def _cleanup_tmp(tmp_dir: Path) -> None:
    """Elimina el directorio temporal y su contenido. Nunca lanza excepciones."""
    try:
        for file in tmp_dir.iterdir():
            file.unlink(missing_ok=True)
        tmp_dir.rmdir()
        logger.debug("Limpiado /tmp: %s", tmp_dir)
    except Exception as exc:  # noqa: BLE001
        logger.warning("No se pudo limpiar %s: %s", tmp_dir, exc)


def _process_single_record(record: dict[str, Any]) -> None:
    """
    Procesa un único SQS Record de principio a fin.

    Flujo:
        1. Parsear evento → S3Object
        2. Derivar video_id → hash_key idéntica a metadata_extractor
        3. DynamoDB: PROCESSING (early write antes de cualquier I/O)
        4. Descargar video a /tmp con boto3
        5. FFmpeg: generar 720p y 480p
        6. Subir ambas versiones a S3 processed
        7. DynamoDB: DONE + output_720p_key + output_480p_key
        8. /tmp limpiado en finally (siempre, incluso si hay excepciones)

    En caso de fallo: escribe FAILED en DynamoDB y re-lanza para SQS retry.
    """
    s3_obj: S3Object = parse_s3_object_from_sqs_record(record)
    logger.info(
        "Iniciando — s3://%s/%s eventTime=%s",
        s3_obj.bucket_name, s3_obj.object_key, s3_obj.event_time,
    )

    video_id: str    = derive_video_id(s3_obj.object_key)
    uploaded_at: str = s3_obj.event_time

    _mark_processing(video_id, uploaded_at)

    tmp_dir: Path | None = None

    try:
        tmp_dir    = Path(tempfile.mkdtemp(prefix=f"ffmpeg_{video_id}_"))
        input_path = tmp_dir / "input.mp4"

        _download_video(s3_obj.bucket_name, s3_obj.object_key, input_path)
        output: TranscodeOutput = _transcode(input_path, tmp_dir, video_id)
        _upload_output(output.local_720p, output.key_720p)
        _upload_output(output.local_480p, output.key_480p)
        _mark_done(video_id, uploaded_at, output.key_720p, output.key_480p)

        logger.info(
            "Completado — video_id=%s 720p=%s 480p=%s",
            video_id, output.key_720p, output.key_480p,
        )

    except Exception as exc:
        _mark_failed(video_id, uploaded_at, f"{type(exc).__name__}: {exc}")
        raise  # re-raise: SQS reintentará hasta max_receive_count → DLQ

    finally:
        if tmp_dir and tmp_dir.exists():
            _cleanup_tmp(tmp_dir)


# ── Handler ───────────────────────────────────────────────────────────────────

def handler(event: dict[str, Any], context: Any) -> dict[str, Any]:
    """
    Punto de entrada de la Lambda.

    batch_size = 1 en el ESM, pero iteramos defensivamente.
    ReportBatchItemFailures: solo el mensaje fallido se reencola.
    """
    records: list[dict[str, Any]] = event.get("Records", [])
    logger.info(
        "Invocación — records=%d request_id=%s remaining_ms=%d",
        len(records),
        context.aws_request_id,
        context.get_remaining_time_in_millis(),
    )

    batch_item_failures: list[dict[str, str]] = []

    for record in records:
        message_id: str = record["messageId"]

        try:
            _process_single_record(record)

        except ValueError as exc:
            # Test event o body inválido — no reintentar
            logger.warning("Record descartado [%s]: %s", message_id, exc)

        except FileNotFoundError as exc:
            # FFmpeg no instalado — error sistémico
            logger.error(
                "FFmpeg no encontrado [%s]: %s — ¿Layer instalado?",
                message_id, exc,
            )
            batch_item_failures.append({"itemIdentifier": message_id})

        except subprocess.CalledProcessError as exc:
            logger.error(
                "FFmpeg falló [%s] returncode=%d stderr=%s",
                message_id,
                exc.returncode,
                (exc.stderr or "")[-500:],
                exc_info=True,
            )
            batch_item_failures.append({"itemIdentifier": message_id})

        except ClientError as exc:
            logger.error(
                "ClientError [%s] code=%s: %s",
                message_id,
                exc.response["Error"]["Code"],
                exc,
                exc_info=True,
            )
            batch_item_failures.append({"itemIdentifier": message_id})

        except Exception as exc:  # noqa: BLE001
            logger.error("Error inesperado [%s]: %s", message_id, exc, exc_info=True)
            batch_item_failures.append({"itemIdentifier": message_id})

    logger.info(
        "Batch finalizado — ok=%d fallidos=%d",
        len(records) - len(batch_item_failures),
        len(batch_item_failures),
    )
    return {"batchItemFailures": batch_item_failures}