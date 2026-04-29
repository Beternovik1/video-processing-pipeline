"""
src/metadata_extractor/handler.py

Lambda handler: extrae metadatos de videos recién subidos al bucket S3 raw
y los persiste en DynamoDB usando update_item (upsert seguro ante race conditions).

── Cadena de eventos desplegada ────────────────────────────────────────────
  S3 PutObject (uploads/*.mp4)
    └─► SNS topic (video-ingest-fanout)
          └─► SQS (metadata-extraction)  [raw_message_delivery = true]
                └─► esta Lambda          [ESM batch_size = 5]

── Estructura del evento que llega a esta Lambda ────────────────────────────
  Con raw_message_delivery = true, el body de cada SQS Record es
  directamente el evento S3 en JSON. NO hay sobre SNS.

  record["body"] contiene:
  {
    "Records": [{
      "eventTime": "2026-04-22T14:30:00.000Z",
      "s3": {
        "bucket": {"name": "video-pipeline-dev-raw-ingestion"},
        "object": {"key": "uploads/video.mp4", "size": 2048}
      }
    }]
  }

── Variables de entorno requeridas ─────────────────────────────────────────
  DYNAMODB_TABLE   nombre exacto de la tabla DynamoDB
  ENVIRONMENT      dev | prod
  LOG_LEVEL        DEBUG | INFO | WARNING | ERROR
"""

import json
import logging
import os
from unittest import result
import boto3
import subprocess
from decimal import Decimal
from urllib.parse import unquote_plus
from datetime import datetime, timezone
from dataclasses import dataclass # <--- ¡EL ESLABÓN PERDIDO!
from typing import Any
from botocore.exceptions import ClientError
import urllib.parse
# ── Logging ───────────────────────────────────────────────────────────────────
_LOG_LEVEL: str = os.environ.get("LOG_LEVEL", "INFO").upper()
logging.basicConfig(
    format="%(asctime)s [%(levelname)s] %(name)s - %(message)s",
    level=_LOG_LEVEL,
)
logger = logging.getLogger(__name__)
logger.setLevel(_LOG_LEVEL)

# ── Variables de entorno ──────────────────────────────────────────────────────
DYNAMODB_TABLE: str = os.environ["DYNAMODB_TABLE"]
ENVIRONMENT: str    = os.environ.get("ENVIRONMENT", "dev")

# ── Clientes AWS — inicializados una vez por contenedor (warm start) ──────────
_s3       = boto3.client("s3")
_dynamodb = boto3.resource("dynamodb")
_table    = _dynamodb.Table(DYNAMODB_TABLE)


# ── Modelos ───────────────────────────────────────────────────────────────────

@dataclass(frozen=True)
class S3Object:
    bucket_name: str
    object_key: str   # decodificado de URL
    event_time: str   # ISO 8601 — range key en DynamoDB

@dataclass(frozen=True)
class BasicMetadata:
    content_length_bytes: int
    content_type: str

@dataclass(frozen=True)
class VideoMetadata:
    duration_seconds: float
    width_px: int
    height_px: int
    codec: str


# ── Parser ────────────────────────────────────────────────────────────────────

def parse_s3_object_from_sqs_record(record: dict[str, Any]) -> S3Object:
    """
    Extrae la referencia al objeto S3 del body de un SQS Record.

    Soporta dos formatos según la configuración de la suscripción SNS:

    Formato A — raw_message_delivery = true (nuestra configuración):
        record["body"] = '{"Records": [{"s3": {...}, "eventTime": "..."}]}'
        El body ES el evento S3 directamente.

    Formato B — raw_message_delivery = false (inyección manual o cambio futuro):
        record["body"] = '{"Message": "{\"Records\": [{...}]}"}'
        El body es el sobre SNS. El evento S3 está en body["Message"] como string.

    La detección es automática: si existe la clave "Message" en el body,
    se desenvuelve. Si no, se usa el body directamente.

    Args:
        record: Un elemento de event["Records"] entregado por SQS.

    Returns:
        S3Object con bucket, key (decodificado de URL) y timestamp del evento.

    Raises:
        ValueError: Si el evento es un test event de S3 o no contiene Records.
        KeyError:   Si faltan claves esperadas en la estructura del evento.
        json.JSONDecodeError: Si el body no es JSON válido.
    """
    # Paso 1: parsear el body de SQS
    body: dict[str, Any] = json.loads(record["body"])

    # Paso 2: desenvolver el sobre SNS si existe (raw_message_delivery = false)
    if "Message" in body and isinstance(body["Message"], str):
        s3_event: dict[str, Any] = json.loads(body["Message"])
    else:
        s3_event = body

    # Paso 3: filtrar test events de S3
    if s3_event.get("Event") == "s3:TestEvent":
        raise ValueError("Test event de S3 — ignorado intencionalmente.")

    # Paso 4: extraer la lista de Records
    s3_records: list[dict[str, Any]] = s3_event.get("Records", [])
    if not s3_records:
        raise ValueError(f"El evento no contiene Records de S3: {s3_event}")

    # Paso 5: tomar el primer record (cada mensaje SQS corresponde a un objeto S3)
    s3_record: dict[str, Any] = s3_records[0]

    # Paso 6: extraer datos del bucket y objeto
    s3_info = s3_record["s3"]
    raw_key: str     = s3_info["object"]["key"]
    decoded_key: str = urllib.parse.unquote_plus(raw_key)

    return S3Object(
        bucket_name=s3_info["bucket"]["name"],
        object_key=decoded_key,
        event_time=s3_record["eventTime"],
    )


# ── Lógica de negocio ─────────────────────────────────────────────────────────

def derive_video_id(object_key: str) -> str:
    """
    Genera el video_id (hash_key de DynamoDB) a partir del object_key de S3.

    Transformación:
        "uploads/carpeta/mi-video.mp4"
          → strip "uploads/"  → "carpeta/mi-video.mp4"
          → strip extensión   → "carpeta/mi-video"
          → "/" → "-"         → "carpeta-mi-video"

    CRÍTICO: Este algoritmo debe ser idéntico al de la Lambda FFmpeg.
    Si difieren, cada Lambda escribe en una fila distinta de DynamoDB.
    """
    key = object_key

    if key.startswith("uploads/"):
        key = key[len("uploads/"):]

    if "." in key:
        key = key.rsplit(".", 1)[0]

    return key.replace("/", "-")


def fetch_basic_metadata(bucket_name: str, object_key: str) -> BasicMetadata:
    """
    Obtiene tamaño y content type del objeto con s3:HeadObject.
    No descarga el archivo — solo lee los headers HTTP.
    """
    logger.info("HeadObject s3://%s/%s", bucket_name, object_key)
    response = _s3.head_object(Bucket=bucket_name, Key=object_key)
    return BasicMetadata(
        content_length_bytes=response["ContentLength"],
        content_type=response.get("ContentType", "application/octet-stream"),
    )


def extract_video_metadata_real(bucket_name: str, object_key: str) -> VideoMetadata | None:
    chunk_path = f"/tmp/{os.path.basename(object_key)}"
    
    try:
        logger.debug(f"Descargando primeros 5MB de s3://{bucket_name}/{object_key}")
        response = _s3.get_object(
            Bucket=bucket_name, 
            Key=object_key, 
            Range='bytes=0-5242880'
        )
        
        with open(chunk_path, 'wb') as f:
            f.write(response['Body'].read())
            
        logger.debug("Llamando a FFprobe localmente...")
        result = subprocess.run(
            [
                "/opt/bin/ffprobe", 
                "-v", "error",
                "-select_streams", "v:0",
                "-show_entries", "stream=width,height,codec_name",
                "-show_entries", "format=duration",
                "-of", "json",
                chunk_path 
            ],
            capture_output=True,
            text=True,
            check=True,
            timeout=10
        )

        data = json.loads(result.stdout)

        # ── Validaciones robustas ───────────────────────────────
        streams = data.get("streams", [])
        if not streams:
            raise ValueError("FFprobe no devolvió streams")

        stream = streams[0]

        width = int(stream.get("width", 0))
        height = int(stream.get("height", 0))
        codec = stream.get("codec_name", "unknown")

        format_info = data.get("format", {})
        duration = float(format_info.get("duration", 0.0))

        return VideoMetadata(
            duration_seconds=round(duration, 2),
            width_px=width,
            height_px=height,
            codec=codec
        )

    except subprocess.CalledProcessError as e:
        logger.error(f"Error de ejecución de FFprobe: {e.stderr}")
        return None

    except Exception as e:
        logger.error(f"Fallo al procesar fragmento con FFprobe: {str(e)}")
        return None

    finally:
        if os.path.exists(chunk_path):
            os.remove(chunk_path)

def write_metadata_to_dynamodb(
    video_id: str,
    uploaded_at: str,
    basic: BasicMetadata,
    video: VideoMetadata,
) -> None:
    """
    Escribe metadatos en DynamoDB con update_item (upsert).

    update_item en lugar de put_item: la Lambda FFmpeg puede estar
    escribiendo en la misma fila al mismo tiempo (fan-out SNS).
    update_item con SET solo toca los atributos especificados — los
    atributos de FFmpeg quedan intactos. put_item sobreescribiría todo.
    """
    now_iso: str    = datetime.now(timezone.utc).isoformat()
    resolution: str = f"{video.width_px}x{video.height_px}"

    logger.info("DynamoDB update_item — video_id=%s uploaded_at=%s", video_id, uploaded_at)

    _table.update_item(
        Key={
            "video_id":    video_id,
            "uploaded_at": uploaded_at,
        },
        UpdateExpression=(
            "SET original_size           = :size, "
            "    original_format         = :fmt,  "
            "    resolution              = :res,  "
            "    duration_seconds        = :dur,  "
            "    codec                   = :codec,"
            "    metadata_extracted_at   = :ts"
        ),
        ExpressionAttributeValues={
            ":size":  basic.content_length_bytes,
            ":fmt":   basic.content_type,
            ":res":   resolution,
            ":dur":   Decimal(str(video.duration_seconds)),
            ":codec": video.codec,
            ":ts":    now_iso,
        },
    )
    logger.info("DynamoDB update_item OK — video_id=%s", video_id)


# ── Handler ───────────────────────────────────────────────────────────────────

def handler(event: dict[str, Any], context: Any) -> dict[str, Any]:
    """
    Punto de entrada de la Lambda.

    Itera el batch de SQS Records. Con ReportBatchItemFailures (configurado
    en Terraform), solo los records fallidos se reencolan — no todo el batch.
    """
    records: list[dict[str, Any]] = event.get("Records", [])
    logger.info(
        "Batch recibido — records=%d request_id=%s",
        len(records),
        context.aws_request_id,
    )

    batch_item_failures: list[dict[str, str]] = []

    for record in records:
        message_id: str = record["messageId"]
        try:
            _process_single_record(record)

        except ValueError as exc:
            # Test events o body malformado — no reintentar
            logger.warning("Record descartado [%s]: %s", message_id, exc)

        except ClientError as exc:
            # Error AWS transitorio (throttling, permisos, etc.) — reintentar
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


def _process_single_record(record: dict[str, Any]) -> None:
    """Procesa un único SQS Record de principio a fin."""
    
    logger.debug("Parseando SQS record...")
    s3_obj = parse_s3_object_from_sqs_record(record)
    logger.info(
        "Objeto recibido: s3://%s/%s  eventTime=%s",
        s3_obj.bucket_name, s3_obj.object_key, s3_obj.event_time,
    )

    video_id = derive_video_id(s3_obj.object_key)
    logger.debug("video_id=%s", video_id)

    logger.debug("Ejecutando HeadObject...")
    basic = fetch_basic_metadata(s3_obj.bucket_name, s3_obj.object_key)
    logger.debug("size=%d bytes  content_type=%s", basic.content_length_bytes, basic.content_type)

    logger.debug("Extrayendo metadatos reales con FFprobe (Streaming)...")
    video = extract_video_metadata_real(s3_obj.bucket_name, s3_obj.object_key)

    if not video:
        logger.warning("Fallo en extracción de metadatos reales. Usando fallback de error.")
        # FIX 3: Usar el Dataclass real
        video = VideoMetadata(
            duration_seconds=0.0,
            width_px=0,
            height_px=0,
            codec="Error"
        )

    write_metadata_to_dynamodb(
        video_id=video_id,
        uploaded_at=s3_obj.event_time,
        basic=basic,
        video=video,
    )

    logger.info("Record completado exitosamente — video_id=%s", video_id)