// The image routes of 0.2.0, kept so the apps of that release go on working. An image is a file
// with a width and a height now (files.rs), and these routes only reach such files. Remove this
// module, its routes and the `images` list in model.rs together, once no 0.2.0 app is left.
use crate::{
    AppState,
    auth::Identity,
    error::{ApiError, Result},
    files::{self, PIXEL_LIMIT},
    items::{Written, item_id, visible_item},
};
use axum::{
    Extension,
    extract::{Path, State},
    response::Response,
};
use base64::{Engine, engine::general_purpose::STANDARD};
use serde_json::{Map, Value};
use sqlx::SqliteConnection;

// What one request may carry. The app sends about half a megabyte per image.
pub const BODY_LIMIT: usize = 8 * 1024 * 1024;
const BYTE_LIMIT: usize = 5 * 1024 * 1024;

// Takes `{"mime": ..., "data": "<base64>"}` apart and checks it as 0.2.0 did. Runs outside the
// write transaction, so a large upload does not keep other writes waiting while it is decoded.
pub(crate) fn prepare(mut fields: Map<String, Value>) -> Result<files::Upload> {
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
            axum::http::StatusCode::PAYLOAD_TOO_LARGE,
            "An image can be at most 5 MB.".into(),
        ));
    }
    // The first bytes decide, not what the sender calls it.
    let (found, kind, name) = if data.starts_with(&[0xFF, 0xD8, 0xFF]) {
        ("image/jpeg", imagesize::ImageType::Jpeg, "Image.jpg")
    } else if data.starts_with(&[0x89, b'P', b'N', b'G', 0x0D, 0x0A, 0x1A, 0x0A]) {
        ("image/png", imagesize::ImageType::Png, "Image.png")
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
    let sha256 = crate::auth::sha256_hex(&data);
    Ok(files::Upload::picture(
        name,
        found,
        sha256,
        (width as i64, height as i64),
        data,
    ))
}

// Whether `image` is one of the item's files that 0.2.0 shows as an image. Another file under
// the same ID is not found here, so an old app cannot remove a file it never saw.
async fn is_image(
    conn: &mut SqliteConnection,
    identity: &Identity,
    id: i64,
    image: i64,
) -> Result<()> {
    let item = visible_item(&mut *conn, id, identity).await?;
    if item
        .files
        .0
        .iter()
        .any(|file| file.id == image && file.is_legacy_image())
    {
        Ok(())
    } else {
        Err(ApiError::missing())
    }
}

pub(crate) async fn remove(
    conn: &mut SqliteConnection,
    identity: &Identity,
    id: i64,
    image: i64,
    fields: Map<String, Value>,
) -> Result<Written> {
    is_image(conn, identity, id, image).await?;
    files::remove(conn, identity, id, image, fields).await
}

pub async fn download(
    State(state): State<AppState>,
    Extension(identity): Extension<Identity>,
    Path((id, image)): Path<(String, String)>,
) -> Result<Response> {
    identity.require("read")?;
    {
        let mut conn = state.db.acquire().await?;
        is_image(&mut conn, &identity, item_id(&id)?, item_id(&image)?).await?;
    }
    files::download(State(state), Extension(identity), Path((id, image))).await
}
