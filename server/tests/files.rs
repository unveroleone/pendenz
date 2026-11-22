// The file routes and the size limit, for the cases a retry, a hidden item or another token can
// get wrong. Each test runs its own scratch server.
mod support;

use serde_json::{Value, json};
use support::*;

async fn status_and_body(response: reqwest::Response) -> (u16, Value) {
    let status = response.status().as_u16();
    let body = response.json().await.unwrap_or(Value::Null);
    (status, body)
}

async fn set_limit(server: &Server, token: &str, mb: Value) -> (u16, Value) {
    let response = reqwest::Client::new()
        .patch(format!("{}/api/settings", server.url()))
        .bearer_auth(token)
        .json(&json!({"file_limit_mb": mb}))
        .send()
        .await
        .unwrap();
    status_and_body(response).await
}

async fn get(server: &Server, token: &str, path: &str) -> reqwest::Response {
    reqwest::Client::new()
        .get(format!("{}/api{path}", server.url()))
        .bearer_auth(token)
        .send()
        .await
        .unwrap()
}

async fn delete(server: &Server, token: &str, path: &str, key: &str) -> (u16, Value) {
    let response = reqwest::Client::new()
        .delete(format!("{}/api{path}", server.url()))
        .bearer_auth(token)
        .header("Idempotency-Key", key)
        .send()
        .await
        .unwrap();
    status_and_body(response).await
}

async fn item(server: &Server, body: Value) -> i64 {
    server
        .api(&server.owner, "POST", "/items", Some(body))
        .await["id"]
        .as_i64()
        .unwrap()
}

#[tokio::test]
async fn a_retry_is_answered_even_after_the_limit_was_lowered() {
    let server = Server::start().await;
    let id = item(&server, json!({"title": "Offer"})).await;
    let data = vec![7u8; 2_000_000];
    let first = server
        .upload(
            &server.owner,
            id,
            ("a.bin", "application/octet-stream", data.clone()),
            "k1",
            None,
        )
        .await;
    assert_eq!(first.status(), 200);
    assert_eq!(set_limit(&server, &server.owner, json!(1)).await.0, 200);
    let (status, body) = status_and_body(
        server
            .upload(
                &server.owner,
                id,
                ("a.bin", "application/octet-stream", data.clone()),
                "k1",
                None,
            )
            .await,
    )
    .await;
    assert_eq!(status, 200, "{body}");
    assert_eq!(body["files"].as_array().unwrap().len(), 1);
    let (status, body) = status_and_body(
        server
            .upload(
                &server.owner,
                id,
                ("b.bin", "application/octet-stream", data),
                "k2",
                None,
            )
            .await,
    )
    .await;
    assert_eq!(status, 413);
    assert_eq!(body["error"], "A file can be at most 1 MB.");
}

#[tokio::test]
async fn the_limit_counts_in_whole_megabytes() {
    let server = Server::start().await;
    let id = item(&server, json!({"title": "Scan"})).await;
    assert_eq!(set_limit(&server, &server.owner, json!(1)).await.0, 200);
    let fits = server
        .upload(
            &server.owner,
            id,
            ("a", "text/plain", vec![b'a'; 1_000_000]),
            "k1",
            None,
        )
        .await;
    assert_eq!(fits.status(), 200);
    let over = server
        .upload(
            &server.owner,
            id,
            ("b", "text/plain", vec![b'a'; 1_000_001]),
            "k2",
            None,
        )
        .await;
    assert_eq!(over.status(), 413);
    let empty = server
        .upload(
            &server.owner,
            id,
            ("c", "text/plain", Vec::new()),
            "k3",
            None,
        )
        .await;
    assert_eq!(empty.status(), 200);
}

#[tokio::test]
async fn the_upload_id_tells_two_files_with_the_same_bytes_apart() {
    let server = Server::start().await;
    let id = item(&server, json!({"title": "Twice"})).await;
    for (key, upload) in [("k1", "A-1"), ("k2", "B-2")] {
        let response = server
            .upload(
                &server.owner,
                id,
                ("same.txt", "text/plain", b"same".to_vec()),
                key,
                Some(upload),
            )
            .await;
        assert_eq!(response.status(), 200);
    }
    let detail = server
        .api(&server.owner, "GET", &format!("/items/{id}"), None)
        .await;
    let uploads: Vec<&str> = detail["item"]["files"]
        .as_array()
        .unwrap()
        .iter()
        .map(|file| file["upload_id"].as_str().unwrap())
        .collect();
    assert_eq!(uploads, ["A-1", "B-2"]);
    let (status, body) = status_and_body(
        server
            .upload(
                &server.owner,
                id,
                ("same.txt", "text/csv", b"same".to_vec()),
                "k1",
                Some("A-1"),
            )
            .await,
    )
    .await;
    assert_eq!(
        status, 400,
        "a key used for another type is refused: {body}"
    );
}

#[tokio::test]
async fn an_agent_cannot_reach_the_files_of_a_hidden_item() {
    let server = Server::start().await;
    let bot = server.token("bot", "read,write");
    let hidden = item(
        &server,
        json!({"title": "Secret", "hidden_from_agents": true}),
    )
    .await;
    let open = item(&server, json!({"title": "Open"})).await;
    let response = server
        .upload(
            &server.owner,
            hidden,
            ("s.txt", "text/plain", b"secret".to_vec()),
            "k1",
            None,
        )
        .await;
    assert_eq!(response.status(), 200);
    let file = 1;
    assert_eq!(
        get(&server, &bot, &format!("/items/{hidden}/files/{file}"))
            .await
            .status(),
        404
    );
    // The hidden item's file, asked for under an item the agent may see.
    assert_eq!(
        get(&server, &bot, &format!("/items/{open}/files/{file}"))
            .await
            .status(),
        404
    );
    let upload = server
        .upload(
            &bot,
            hidden,
            ("x.txt", "text/plain", b"x".to_vec()),
            "b1",
            None,
        )
        .await;
    assert_eq!(upload.status(), 404);
    let (status, _) = delete(
        &server,
        &bot,
        &format!("/items/{hidden}/files/{file}"),
        "b2",
    )
    .await;
    assert_eq!(status, 404);
    // The owner still has it.
    assert_eq!(
        get(
            &server,
            &server.owner,
            &format!("/items/{hidden}/files/{file}")
        )
        .await
        .status(),
        200
    );
}

#[tokio::test]
async fn a_token_without_read_gets_a_receipt() {
    let server = Server::start().await;
    let writer = server.token("writer", "write");
    let id = item(&server, json!({"title": "Drop box"})).await;
    for _ in 0..2 {
        let (status, body) = status_and_body(
            server
                .upload(
                    &writer,
                    id,
                    ("a.txt", "text/plain", b"a".to_vec()),
                    "w1",
                    None,
                )
                .await,
        )
        .await;
        assert_eq!(status, 200);
        assert!(
            body.get("files").is_none(),
            "a receipt, not the row: {body}"
        );
    }
}

#[tokio::test]
async fn only_the_owner_changes_the_limit() {
    let server = Server::start().await;
    let bot = server.token("bot", "read,write");
    let (status, body) = status_and_body(get(&server, &bot, "/settings").await).await;
    assert_eq!(status, 200);
    assert_eq!(
        body,
        json!({"file_limit_mb": 25, "file_limit_ceiling_mb": 100, "energy_price_chf": null})
    );
    assert_eq!(set_limit(&server, &bot, json!(50)).await.0, 403);
    for wrong in [json!(0), json!(101), json!(2.5), json!("10")] {
        assert_eq!(set_limit(&server, &server.owner, wrong).await.0, 400);
    }
    let (status, body) = set_limit(&server, &server.owner, json!(100)).await;
    assert_eq!(status, 200);
    assert_eq!(body["file_limit_mb"], 100);
    let changes = server.api(&bot, "GET", "/changes?cursor=0", None).await;
    assert_eq!(changes["settings"]["file_limit_mb"], 100);
}

#[tokio::test]
async fn a_file_is_sent_as_a_download() {
    let server = Server::start().await;
    let id = item(&server, json!({"title": "Page"})).await;
    let page = b"<script>alert(1)</script>".to_vec();
    let response = server
        .upload(
            &server.owner,
            id,
            ("Seite \u{fc}.html", "text/html", page.clone()),
            "k1",
            None,
        )
        .await;
    assert_eq!(response.status(), 200);
    let response = get(&server, &server.owner, &format!("/items/{id}/files/1")).await;
    let header = |name: &str| response.headers()[name].to_str().unwrap().to_owned();
    assert_eq!(header("content-type"), "text/html");
    assert_eq!(
        header("content-disposition"),
        "attachment; filename*=UTF-8''Seite%20%C3%BC%2Ehtml"
    );
    assert_eq!(header("content-security-policy"), "sandbox");
    assert_eq!(header("x-content-type-options"), "nosniff");
    assert_eq!(response.bytes().await.unwrap().to_vec(), page);
}

#[tokio::test]
async fn a_trashed_item_keeps_its_files_but_takes_no_new_ones() {
    let server = Server::start().await;
    let id = item(&server, json!({"title": "Old"})).await;
    let response = server
        .upload(
            &server.owner,
            id,
            ("a.txt", "text/plain", b"a".to_vec()),
            "k1",
            None,
        )
        .await;
    let version = response.json::<Value>().await.unwrap()["version"].clone();
    server
        .api(
            &server.owner,
            "PATCH",
            &format!("/items/{id}"),
            Some(json!({"version": version, "trashed": true})),
        )
        .await;
    assert_eq!(
        get(&server, &server.owner, &format!("/items/{id}/files/1"))
            .await
            .status(),
        200
    );
    let added = server
        .upload(
            &server.owner,
            id,
            ("b.txt", "text/plain", b"b".to_vec()),
            "k2",
            None,
        )
        .await;
    assert_eq!(added.status(), 400);
    let (status, _) = delete(
        &server,
        &server.owner,
        &format!("/items/{id}/files/1"),
        "k3",
    )
    .await;
    assert_eq!(status, 400);
}

#[tokio::test]
async fn names_that_look_like_paths_are_refused() {
    let server = Server::start().await;
    let id = item(&server, json!({"title": "Names"})).await;
    for (index, name) in ["", ".", "..", "a/b", "a\\b", "a\u{7}b"]
        .into_iter()
        .enumerate()
    {
        let response = server
            .upload(
                &server.owner,
                id,
                (name, "text/plain", b"x".to_vec()),
                &format!("n{index}"),
                None,
            )
            .await;
        assert_eq!(response.status(), 400, "{name:?}");
    }
}

// A PNG that names its size in the header and holds nothing else. Enough for the server to
// read the size, which is all it reads.
fn png_of(width: u32, height: u32) -> Vec<u8> {
    let mut data = b"\x89PNG\r\n\x1a\n\0\0\0\x0dIHDR".to_vec();
    data.extend(width.to_be_bytes());
    data.extend(height.to_be_bytes());
    data.extend([8, 6, 0, 0, 0, 0, 0, 0, 0]);
    data
}

#[tokio::test]
async fn a_picture_gets_its_size_and_any_other_file_none() {
    let server = Server::start().await;
    let id = item(&server, json!({"title": "Receipts"})).await;
    for (name, mime, data, key) in [
        ("photo.png", "image/png", PNG.to_vec(), "p1"),
        // The bytes decide, not the type the sender names.
        ("scan", "application/octet-stream", png_of(300, 200), "p2"),
        ("notes.txt", "text/plain", b"hello".to_vec(), "p3"),
        // More pixels than anyone should have to draw: a file without a size.
        ("huge.png", "image/png", png_of(10_000, 5_000), "p4"),
    ] {
        let response = server
            .upload(&server.owner, id, (name, mime, data), key, None)
            .await;
        assert!(response.status().is_success(), "{name}");
    }
    let detail = server
        .api(&server.owner, "GET", &format!("/items/{id}"), None)
        .await;
    let files = &detail["item"]["files"];
    assert_eq!(
        (files[0]["width"].clone(), files[0]["height"].clone()),
        (json!(1), json!(1))
    );
    assert_eq!(
        (files[1]["width"].clone(), files[1]["height"].clone()),
        (json!(300), json!(200))
    );
    assert!(files[2].get("width").is_none());
    assert!(files[3].get("width").is_none());
    // Only a JPEG or PNG with its type named so is an image to an app of 0.2.0.
    let images: Vec<i64> = detail["item"]["images"]
        .as_array()
        .unwrap()
        .iter()
        .map(|image| image["id"].as_i64().unwrap())
        .collect();
    assert_eq!(images, [1]);
}

#[tokio::test]
async fn the_old_image_routes_reach_pictures_only() {
    let server = Server::start().await;
    let id = item(&server, json!({"title": "Car"})).await;
    let added = server
        .api(
            &server.owner,
            "POST",
            &format!("/items/{id}/images"),
            Some(json!({"mime": "image/png", "data": png_base64()})),
        )
        .await;
    assert_eq!(added["files"][0]["name"], "Image.png");
    assert_eq!(added["files"][0]["width"], 1);
    assert_eq!(added["images"][0]["id"], added["files"][0]["id"]);
    let response = server
        .upload(
            &server.owner,
            id,
            ("Offer.pdf", "application/pdf", b"%PDF".to_vec()),
            "f1",
            None,
        )
        .await;
    assert!(response.status().is_success());

    let picture = get(&server, &server.owner, &format!("/items/{id}/images/1")).await;
    assert_eq!(picture.status(), 200);
    assert_eq!(picture.bytes().await.unwrap().to_vec(), PNG);
    // The PDF is a file under ID 2, and no image.
    assert_eq!(
        get(&server, &server.owner, &format!("/items/{id}/images/2"))
            .await
            .status(),
        404
    );
    let (status, _) = delete(
        &server,
        &server.owner,
        &format!("/items/{id}/images/2"),
        "d1",
    )
    .await;
    assert_eq!(status, 404);

    let (status, body) = delete(
        &server,
        &server.owner,
        &format!("/items/{id}/images/1"),
        "d2",
    )
    .await;
    assert_eq!(status, 200);
    assert_eq!(body["files"].as_array().unwrap().len(), 1);
    assert_eq!(body["files"][0]["name"], "Offer.pdf");
    assert_eq!(body["images"], json!([]));
}
