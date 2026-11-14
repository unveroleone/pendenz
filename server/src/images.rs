use crate::{
    AppState,
    auth::Identity,
    error::{ApiError, Result},
    items::{About, NOW, Written, item_id, next_seq, record, visible_item},
    model::{ImageRef, Item},
};
use axum::{
    Extension,
    extract::{Path, State},
    http::{HeaderValue, StatusCode, header},
    response::{IntoResponse, Response},
};
use base64::{Engine, engine::general_purpose::STANDARD};
use serde_json::{Map, Value, json};
use sha2::{Digest, Sha256};
use sqlx::SqliteConnection;

// What one request may carry. The app sends about half a megabyte per image.
pub const BODY_LIMIT: usize = 8 * 1024 * 1024;
const BYTE_LIMIT: usize = 5 * 1024 * 1024;
// A small file can announce a huge picture. Whoever opens it would need the memory for it.
const PIXEL_LIMIT: u64 = 40_000_000;
const PER_ITEM: usize = 20;

// An upload that was decoded and checked, before the writer lock is taken.
pub(crate) struct Upload {
    mime: &'static str,
    width: i64,
    height: i64,
    pub sha256: String,
    data: Vec<u8>,
}

// Takes `{"mime": ..., "data": "<base64>"}` apart. Runs outside the write transaction, so a
// large upload does not keep other writes waiting while it is decoded.
pub(crate) fn prepare(mut fields: Map<String, Value>) -> Result<Upload> {
    let shape =
        || ApiError::bad("Send mime (image/jpeg or image/png) and data (the image as base64).");
    let (Some(Value::String(mime)), Some(Value::String(text)), true) = (
        fields.remove("mime"),
        fields.remove("data"),
        fields.is_empty(),
    ) else {
        return Err(shape());
    };
    let data = STANDARD
        .decode(text.as_bytes())
        .map_err(|_| ApiError::bad("data is not valid base64."))?;
    if data.is_empty() || data.len() > BYTE_LIMIT {
        return Err(ApiError(
            StatusCode::PAYLOAD_TOO_LARGE,
            "An image can be at most 5 MB.".into(),
        ));
    }
    // The first bytes decide, not what the sender calls it.
    let (found, kind) = if data.starts_with(&[0xFF, 0xD8, 0xFF]) {
        ("image/jpeg", imagesize::ImageType::Jpeg)
    } else if data.starts_with(&[0x89, b'P', b'N', b'G', 0x0D, 0x0A, 0x1A, 0x0A]) {
        ("image/png", imagesize::ImageType::Png)
    } else {
        return Err(ApiError::bad("Only JPEG and PNG images can be attached."));
    };
    if mime != found {
        return Err(ApiError::bad(format!(
            "mime says {mime}, but the data is {found}."
        )));
    }
    let unreadable = || ApiError::bad("The image could not be read.");
    if imagesize::image_type(&data).map_err(|_| unreadable())? != kind {
        return Err(unreadable());
    }
    let size = imagesize::blob_size(&data).map_err(|_| unreadable())?;
    let (width, height) = (size.width as u64, size.height as u64);
    if width == 0 || height == 0 || width.saturating_mul(height) > PIXEL_LIMIT {
        return Err(ApiError::bad(
            "An image can have at most 40 million pixels.",
        ));
    }
    Ok(Upload {
        mime: found,
        width: width as i64,
        height: height as i64,
        sha256: format!("{:x}", Sha256::digest(&data)),
        data,
    })
}

// The item an image write is about. Hidden from this token or missing: 404, as for any read.
async fn open_item(conn: &mut SqliteConnection, identity: &Identity, id: i64) -> Result<Item> {
    let item = visible_item(&mut *conn, id, identity).await?;
    if item.trashed {
        return Err(ApiError::bad(
            "This item is in the trash. Restore it before changing its images.",
        ));
    }
    Ok(item)
}

async fn store_list(
    conn: &mut SqliteConnection,
    identity: &Identity,
    id: i64,
    images: &[ImageRef],
) -> Result<Item> {
    let seq = next_seq(conn).await?;
    let item = sqlx::query_as::<_, Item>(&format!(
        "UPDATE items SET images = ?, version = version + 1, seq = ?, updated_by = ?, \
         updated_at = {NOW} WHERE id = ? RETURNING *"
    ))
    .bind(json!(images).to_string())
    .bind(seq)
    .bind(&identity.actor.id)
    .bind(id)
    .fetch_one(&mut *conn)
    .await?;
    Ok(item)
}

fn written(item: &Item) -> Written {
    Written {
        resource: "item",
        id: item.id.to_string(),
        body: json!(item),
    }
}

pub(crate) async fn add(
    conn: &mut SqliteConnection,
    identity: &Identity,
    id: i64,
    upload: Upload,
) -> Result<Written> {
    let mut images = open_item(conn, identity, id).await?.images;
    if images.len() >= PER_ITEM {
        return Err(ApiError::bad("An item can hold at most 20 images."));
    }
    let bytes = upload.data.len() as i64;
    let image: i64 =
        sqlx::query_scalar("INSERT INTO item_images(item_id, data) VALUES (?, ?) RETURNING id")
            .bind(id)
            .bind(upload.data)
            .fetch_one(&mut *conn)
            .await?;
    images.push(ImageRef {
        id: image,
        mime: upload.mime.into(),
        width: upload.width,
        height: upload.height,
        bytes,
        sha256: upload.sha256,
    });
    let item = store_list(conn, identity, id, &images).await?;
    record(
        conn,
        About::Item(id),
        &identity.actor.id,
        "image_added",
        json!({"image_id": image, "bytes": bytes}),
    )
    .await?;
    Ok(written(&item))
}

pub(crate) async fn remove(
    conn: &mut SqliteConnection,
    identity: &Identity,
    id: i64,
    image: i64,
    fields: Map<String, Value>,
) -> Result<Written> {
    if !fields.is_empty() {
        return Err(ApiError::bad("Removing an image takes no fields."));
    }
    let mut images = open_item(conn, identity, id).await?.images;
    // The image has to be one of this item's. Its ID under another item is not found.
    let Some(at) = images.iter().position(|entry| entry.id == image) else {
        return Err(ApiError::missing());
    };
    let gone = images.remove(at);
    sqlx::query("DELETE FROM item_images WHERE id = ? AND item_id = ?")
        .bind(image)
        .bind(id)
        .execute(&mut *conn)
        .await?;
    let item = store_list(conn, identity, id, &images).await?;
    record(
        conn,
        About::Item(id),
        &identity.actor.id,
        "image_removed",
        json!({"image_id": image, "sha256": gone.sha256}),
    )
    .await?;
    Ok(written(&item))
}

// The bytes of one image. The item decides who may see it, and the image is looked up under
// that item: an agent cannot reach the image of a hidden item through one it may see.
pub async fn download(
    State(state): State<AppState>,
    Extension(identity): Extension<Identity>,
    Path((id, image)): Path<(String, String)>,
) -> Result<Response> {
    identity.require("read")?;
    let (id, image) = (item_id(&id)?, item_id(&image)?);
    let mut tx = state.db.begin().await?;
    let item = visible_item(&mut *tx, id, &identity).await?;
    let Some(entry) = item.images.iter().find(|entry| entry.id == image) else {
        return Err(ApiError::missing());
    };
    let data: Vec<u8> =
        sqlx::query_scalar("SELECT data FROM item_images WHERE id = ? AND item_id = ?")
            .bind(image)
            .bind(id)
            .fetch_optional(&mut *tx)
            .await?
            .ok_or_else(ApiError::missing)?;
    let mime = HeaderValue::from_str(&entry.mime)
        .unwrap_or(HeaderValue::from_static("application/octet-stream"));
    Ok((
        [
            (header::CONTENT_TYPE, mime),
            (
                header::X_CONTENT_TYPE_OPTIONS,
                HeaderValue::from_static("nosniff"),
            ),
        ],
        data,
    )
        .into_response())
}
