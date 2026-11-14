use axum::{
    Json,
    http::{StatusCode, header},
    response::{IntoResponse, Response},
};
use serde_json::json;

pub struct ApiError(pub StatusCode, pub String);
pub type Result<T> = std::result::Result<T, ApiError>;

impl ApiError {
    pub fn bad(message: impl Into<String>) -> Self {
        Self(StatusCode::BAD_REQUEST, message.into())
    }
    pub fn conflict() -> Self {
        Self(
            StatusCode::CONFLICT,
            "This item changed. Read it again before saving.".into(),
        )
    }
    pub fn unauthorized() -> Self {
        Self(
            StatusCode::UNAUTHORIZED,
            "Send a valid bearer token.".into(),
        )
    }
    pub fn forbidden() -> Self {
        Self(
            StatusCode::FORBIDDEN,
            "This token cannot perform that action.".into(),
        )
    }
    pub fn missing() -> Self {
        Self(StatusCode::NOT_FOUND, "Not found.".into())
    }
}
impl IntoResponse for ApiError {
    fn into_response(self) -> Response {
        let body = Json(json!({"error": self.1}));
        if self.0 == StatusCode::UNAUTHORIZED {
            (self.0, [(header::WWW_AUTHENTICATE, "Bearer")], body).into_response()
        } else {
            (self.0, body).into_response()
        }
    }
}
impl From<sqlx::Error> for ApiError {
    fn from(error: sqlx::Error) -> Self {
        tracing::error!(%error, "Database operation failed");
        Self(
            StatusCode::INTERNAL_SERVER_ERROR,
            "The server could not complete this request. Retry it.".into(),
        )
    }
}
