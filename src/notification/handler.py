"""
src/notification/handler.py

Lambda de sincronización: lee el DynamoDB Stream y publica en SNS
cuando un video está completamente procesado por AMBAS Lambdas.

── Cadena de eventos ────────────────────────────────────────────────────────
  DynamoDB write (metadata_extractor o ffmpeg_processor)
    └─► DynamoDB Stream (NEW_AND_OLD_IMAGES)
          └─► esta Lambda   [ESM con filter_criteria en processing_status]

── Lógica de Join (sincronización entre dos procesos independientes) ────────
  metadata_extractor escribe: metadata_extracted_at, resolution, codec...
  ffmpeg_processor   escribe: transcoding_status = "DONE", output_720p_key...

  El DynamoDB Stream dispara esta Lambda en CADA escritura de cualquiera
  de las dos Lambdas. Por eso se necesita un Join estricto:

  Solo publicar en SNS si el ítem tiene AMBOS:
    1. transcoding_status == "DONE"    (FFmpeg terminó)
    2. metadata_extracted_at presente  (Metadata terminó)

  Si solo una terminó, la otra aún no llegó. Silencio — la próxima
  escritura disparará otra invocación y se evaluará de nuevo.

── Por qué este diseño es robusto ──────────────────────────────────────────
  No hay polling, no hay sleep(), no hay coordinación explícita.
  Cada update_item del Stream es un evento. La Lambda evalúa el estado
  del ítem completo en ese instante. El orden de llegada no importa:
  sea que FFmpeg termine primero o Metadata primero, la segunda escritura
  siempre tiene ambos campos y dispara la notificación.

── Variables de entorno requeridas ─────────────────────────────────────────
  SNS_ALERTS_TOPIC  ARN del SNS topic de alertas al operador
  ENVIRONMENT       dev | prod
  LOG_LEVEL         DEBUG | INFO | WARNING | ERROR
"""

from __future__ import annotations

import json
import logging
import os
from datetime import datetime, timezone
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
SNS_ALERTS_TOPIC: str = os.environ["SNS_ALERTS_TOPIC"]
ENVIRONMENT: str      = os.environ.get("ENVIRONMENT", "dev")

# ── Cliente SNS — module-level para warm starts ───────────────────────────────
_sns = boto3.client("sns")

# Tipos de evento del DynamoDB Stream que nos interesan
_RELEVANT_EVENT_TYPES: frozenset[str] = frozenset({"INSERT", "MODIFY"})


# ── Helpers de DynamoDB Stream ────────────────────────────────────────────────

def _get_string_attr(image: dict[str, Any], attribute_name: str) -> str | None:
    """
    Extrae el valor de un atributo de tipo String de un DynamoDB Image.

    Los atributos en el Stream vienen en formato DynamoDB:
        {"atributo": {"S": "valor"}}   para strings
        {"atributo": {"N": "123"}}     para números
        {"atributo": {"BOOL": true}}   para booleanos

    Args:
        image:          NewImage o OldImage del Stream record.
        attribute_name: Nombre del atributo a extraer.

    Returns:
        El valor string si existe y es de tipo "S", None en caso contrario.
    """
    attr = image.get(attribute_name)
    if attr is None:
        return None
    return attr.get("S")


def _attr_exists(image: dict[str, Any], attribute_name: str) -> bool:
    """Verifica si un atributo existe en el DynamoDB Image (cualquier tipo)."""
    return attribute_name in image


# ── Lógica de Join ────────────────────────────────────────────────────────────

def _is_fully_processed(new_image: dict[str, Any]) -> bool:
    """
    Evalúa si el ítem tiene ambos procesos completados.

    Condición de Join — deben cumplirse AMBAS simultáneamente:
      1. transcoding_status == "DONE"     → ffmpeg_processor terminó exitosamente
      2. metadata_extracted_at presente   → metadata_extractor terminó (cualquier resultado)

    El campo metadata_extracted_at lo escribe metadata_extractor al final
    de su ejecución, incluyendo el fallback — siempre está presente si la
    Lambda de metadata corrió hasta completion.

    Args:
        new_image: El NewImage del DynamoDB Stream record (estado actual del ítem).

    Returns:
        True si y solo si ambas condiciones se cumplen.
    """
    transcoding_status: str | None = _get_string_attr(new_image, "transcoding_status")
    metadata_done: bool             = _attr_exists(new_image, "metadata_extracted_at")

    ffmpeg_done: bool = transcoding_status == "DONE"

    logger.debug(
        "Join check — transcoding_status=%s metadata_extracted_at_exists=%s",
        transcoding_status,
        metadata_done,
    )

    return ffmpeg_done and metadata_done


# ── SNS — publicación de alerta ───────────────────────────────────────────────

def _build_notification_message(
    video_id: str,
    new_image: dict[str, Any],
) -> str:
    """
    Construye el mensaje de texto plano que llegará al email del operador.

    SNS entrega el mensaje como texto crudo cuando el operador está suscrito
    con Protocol: Email. El formato legible es prioritario sobre JSON.

    Args:
        video_id:  Identificador del video (hash_key de DynamoDB).
        new_image: NewImage completo del Stream para extraer detalles.

    Returns:
        String multilínea listo para publicar en SNS.
    """
    now_iso: str = datetime.now(timezone.utc).isoformat()

    key_720p: str = _get_string_attr(new_image, "output_720p_key") or "N/A"
    key_480p: str = _get_string_attr(new_image, "output_480p_key") or "N/A"
    codec: str    = _get_string_attr(new_image, "codec")           or "N/A"
    resolution: str = _get_string_attr(new_image, "resolution")    or "N/A"

    return (
        f"Video completamente procesado\n"
        f"{'─' * 40}\n"
        f"video_id:    {video_id}\n"
        f"entorno:     {ENVIRONMENT}\n"
        f"resolución:  {resolution}\n"
        f"codec:       {codec}\n"
        f"output 720p: {key_720p}\n"
        f"output 480p: {key_480p}\n"
        f"notificado:  {now_iso}\n"
        f"{'─' * 40}\n"
        f"Ambos procesos completados: metadatos extraídos y transcodificación lista."
    )


def _publish_notification(video_id: str, uploaded_at: str, new_image: dict[str, Any]) -> None:
    """
    Publica la notificación y marca en DynamoDB que ya se envió.
    """
    message: str = _build_notification_message(video_id, new_image)

    logger.info("Publicando en SNS — video_id=%s topic=%s", video_id, SNS_ALERTS_TOPIC)

    _sns.publish(
        TopicArn=SNS_ALERTS_TOPIC,
        Subject=f"[{ENVIRONMENT.upper()}] Video procesado: {video_id}",
        Message=message,
    )

    logger.info("SNS publicado exitosamente — video_id=%s. Marcando en DB...", video_id)
    
    # Marcamos en DB que ya se notificó para evitar correos duplicados en el futuro
    now_iso: str = datetime.now(timezone.utc).isoformat()
    try:
        dynamodb = boto3.resource("dynamodb")
        table = dynamodb.Table(os.environ.get("DYNAMODB_TABLE", ""))
        table.update_item(
            Key={"video_id": video_id, "uploaded_at": uploaded_at},
            UpdateExpression="SET notification_sent_at = :ts",
            ExpressionAttributeValues={":ts": now_iso}
        )
    except Exception as e:
        logger.error("No se pudo marcar la notificación en DynamoDB: %s", e)

# ── Procesamiento de un record del Stream ────────────────────────────────────

def _process_stream_record(stream_record: dict[str, Any]) -> None:
    """
    Evalúa un único registro del DynamoDB Stream.

    Solo actúa en INSERT y MODIFY — REMOVE no es relevante para este pipeline.
    Solo publica si el join está completo (ambos procesos terminaron).

    Args:
        stream_record: Un elemento de event["Records"] del DynamoDB Stream.
    """
    event_name: str = stream_record.get("eventName", "")

    if event_name not in _RELEVANT_EVENT_TYPES:
        logger.debug("Evento ignorado — eventName=%s", event_name)
        return

    dynamodb_data: dict[str, Any] = stream_record.get("dynamodb", {})
    new_image: dict[str, Any]     = dynamodb_data.get("NewImage", {})

    if not new_image:
        logger.warning("Record sin NewImage — eventName=%s", event_name)
        return

    video_id: str | None    = _get_string_attr(new_image, "video_id")
    uploaded_at: str | None = _get_string_attr(new_image, "uploaded_at")

    if not video_id or not uploaded_at:
        logger.warning(
            "NewImage sin video_id o uploaded_at — keys incompletas: %s",
            list(new_image.keys()),
        )
        return

    logger.debug(
        "Evaluando join — video_id=%s eventName=%s",
        video_id, event_name,
    )

    if not _is_fully_processed(new_image):
        logger.info(
            "Join incompleto — video_id=%s (esperando el otro proceso)",
            video_id,
        )
        return

    # Verificar si ya mandamos la notificación antes (EL CANDADO)
    if _attr_exists(new_image, "notification_sent_at"):
        logger.info("Video %s ya fue notificado previamente. Ignorando.", video_id)
        return

    # Ambas condiciones cumplidas y no notificado antes: publicar
    logger.info("Join completo — video_id=%s publicando alerta", video_id)
    # Pasamos uploaded_at porque la DB lo necesita como Range Key
    _publish_notification(video_id, uploaded_at, new_image) 
    # ==============================

# ── Handler ───────────────────────────────────────────────────────────────────

def handler(event: dict[str, Any], context: Any) -> dict[str, Any]:
    """
    Punto de entrada de la Lambda.

    El ESM tiene filter_criteria para processing_status en el NewImage,
    lo que reduce invocaciones innecesarias. Pero esta Lambda evalúa
    el join completo internamente — el filtro es una optimización de costo,
    no una garantía de correctitud.

    Responde con batchItemFailures para que el Stream solo reintente
    los records fallidos (bisect_batch_on_function_error = true en el ESM
    aísla registros corruptos sin bloquear el shard completo).
    """
    records: list[dict[str, Any]] = event.get("Records", [])
    logger.info(
        "Invocación — records=%d request_id=%s",
        len(records),
        context.aws_request_id,
    )

    batch_item_failures: list[dict[str, str]] = []

    for stream_record in records:
        # El sequence_number identifica registros del Stream (no messageId de SQS)
        sequence_number: str = (
            stream_record.get("dynamodb", {}).get("SequenceNumber", "unknown")
        )

        try:
            _process_stream_record(stream_record)

        except ClientError as exc:
            logger.error(
                "ClientError SNS [seq=%s] code=%s: %s",
                sequence_number,
                exc.response["Error"]["Code"],
                exc,
                exc_info=True,
            )
            batch_item_failures.append({"itemIdentifier": sequence_number})

        except Exception as exc:  # noqa: BLE001
            logger.error(
                "Error inesperado [seq=%s]: %s",
                sequence_number, exc, exc_info=True,
            )
            batch_item_failures.append({"itemIdentifier": sequence_number})

    logger.info(
        "Batch finalizado — ok=%d fallidos=%d",
        len(records) - len(batch_item_failures),
        len(batch_item_failures),
    )
    return {"batchItemFailures": batch_item_failures}