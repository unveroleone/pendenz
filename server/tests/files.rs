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

// Notes hold files the same way. These are the cases above, for a note.

async fn note(server: &Server, body: Value) -> i64 {
    server
        .api(&server.owner, "POST", "/notes", Some(body))
        .await["id"]
        .as_i64()
        .unwrap()
}

async fn note_actions(server: &Server, id: i64) -> Vec<String> {
    server
        .api(
            &server.owner,
            "GET",
            &format!("/notes/{id}?activity=20"),
            None,
        )
        .await["activity"]
        .as_array()
        .unwrap()
        .iter()
        .map(|entry| entry["action"].as_str().unwrap().to_string())
        .collect()
}

#[tokio::test]
async fn a_note_holds_files_like_an_item() {
    let server = Server::start().await;
    let id = note(&server, json!({"body": "Trip\nReceipts"})).await;
    let picture = png_of(30, 20);
    let (status, body) = status_and_body(
        server
            .upload_to(
                &server.owner,
                &format!("/notes/{id}"),
                ("Receipt.png", "image/png", picture.clone()),
                "k1",
                Some("upload-1"),
            )
            .await,
    )
    .await;
    assert_eq!(status, 200, "{body}");
    assert_eq!(body["id"], id);
    assert_eq!(body["version"], 2);
    assert_eq!(body["body"], "Trip\nReceipts");
    let file = &body["files"][0];
    assert_eq!(file["name"], "Receipt.png");
    assert_eq!(file["upload_id"], "upload-1");
    assert_eq!(
        (file["width"].clone(), file["height"].clone()),
        (json!(30), json!(20))
    );
    // A note has no old `images` list: no app of 0.2.0 knew files on notes.
    assert!(body.get("images").is_none());
    let file = file["id"].as_i64().unwrap();

    let download = get(&server, &server.owner, &format!("/notes/{id}/files/{file}")).await;
    assert_eq!(download.status(), 200);
    assert_eq!(download.headers()["content-type"], "image/png");
    assert_eq!(download.bytes().await.unwrap().to_vec(), picture);

    // The changes feed carries the list, so the apps learn of it.
    let changes = server
        .api(&server.owner, "GET", "/changes?cursor=0", None)
        .await;
    let row = changes["changes"]
        .as_array()
        .unwrap()
        .iter()
        .find(|change| change["type"] == "note")
        .unwrap();
    assert_eq!(row["data"]["files"][0]["id"], file);

    let (status, body) = delete(
        &server,
        &server.owner,
        &format!("/notes/{id}/files/{file}"),
        "k2",
    )
    .await;
    assert_eq!(status, 200, "{body}");
    assert_eq!(body["files"], json!([]));
    assert_eq!(
        get(&server, &server.owner, &format!("/notes/{id}/files/{file}"))
            .await
            .status(),
        404
    );
    let actions = note_actions(&server, id).await;
    assert_eq!(actions[..2], ["file_removed", "file_added"]);
}

#[tokio::test]
async fn a_note_file_is_found_only_under_its_note() {
    let server = Server::start().await;
    // The first item and the first note share their number, and so do their first files.
    let item = item(&server, json!({"title": "Offer"})).await;
    let first = note(&server, json!({"body": "First"})).await;
    let second = note(&server, json!({"body": "Second"})).await;
    assert_eq!(item, first);
    for (holder, data, key) in [
        (format!("/items/{item}"), b"item bytes".to_vec(), "k1"),
        (format!("/notes/{first}"), b"note bytes".to_vec(), "k2"),
    ] {
        let response = server
            .upload_to(
                &server.owner,
                &holder,
                ("a.txt", "text/plain", data),
                key,
                None,
            )
            .await;
        assert_eq!(response.status(), 200);
    }
    let bytes = |path: String| {
        let server = &server;
        async move {
            let response = get(server, &server.owner, &path).await;
            (
                response.status().as_u16(),
                response.bytes().await.unwrap().to_vec(),
            )
        }
    };
    assert_eq!(
        bytes(format!("/items/{item}/files/1")).await,
        (200, b"item bytes".to_vec())
    );
    assert_eq!(
        bytes(format!("/notes/{first}/files/1")).await,
        (200, b"note bytes".to_vec())
    );
    assert_eq!(bytes(format!("/notes/{second}/files/1")).await.0, 404);
    let (status, _) = delete(
        &server,
        &server.owner,
        &format!("/notes/{second}/files/1"),
        "k3",
    )
    .await;
    assert_eq!(status, 404);
    assert_eq!(
        bytes(format!("/notes/{first}/files/1")).await,
        (200, b"note bytes".to_vec())
    );
}

#[tokio::test]
async fn an_agent_cannot_reach_the_files_of_a_hidden_note() {
    let server = Server::start().await;
    let bot = server.token("bot", "read,write");
    let hidden = note(
        &server,
        json!({"body": "Secret", "hidden_from_agents": true}),
    )
    .await;
    let open = note(&server, json!({"body": "Open"})).await;
    let response = server
        .upload_to(
            &server.owner,
            &format!("/notes/{hidden}"),
            ("s.txt", "text/plain", b"secret".to_vec()),
            "k1",
            None,
        )
        .await;
    assert_eq!(response.status(), 200);
    for path in [
        format!("/notes/{hidden}/files/1"),
        // The hidden note's file, asked for under a note the agent may see.
        format!("/notes/{open}/files/1"),
    ] {
        assert_eq!(get(&server, &bot, &path).await.status(), 404, "{path}");
    }
    let upload = server
        .upload_to(
            &bot,
            &format!("/notes/{hidden}"),
            ("x.txt", "text/plain", b"x".to_vec()),
            "b1",
            None,
        )
        .await;
    assert_eq!(upload.status(), 404);
    let (status, _) = delete(&server, &bot, &format!("/notes/{hidden}/files/1"), "b2").await;
    assert_eq!(status, 404);

    // An agent's upload to a note it may see, retried after the owner hid the note.
    let open_path = format!("/notes/{open}");
    let send = || {
        server.upload_to(
            &bot,
            &open_path,
            ("b.txt", "text/plain", b"b".to_vec()),
            "b3",
            None,
        )
    };
    assert_eq!(send().await.status(), 200);
    let version = server
        .api(&server.owner, "GET", &format!("/notes/{open}"), None)
        .await["note"]["version"]
        .clone();
    server
        .api(
            &server.owner,
            "PATCH",
            &format!("/notes/{open}"),
            Some(json!({"version": version, "hidden_from_agents": true})),
        )
        .await;
    assert_eq!(send().await.status(), 404);
    // The owner still has both.
    for path in [
        format!("/notes/{hidden}/files/1"),
        format!("/notes/{open}/files/2"),
    ] {
        assert_eq!(
            get(&server, &server.owner, &path).await.status(),
            200,
            "{path}"
        );
    }
}

#[tokio::test]
async fn a_trashed_note_keeps_its_files_but_takes_no_new_ones() {
    let server = Server::start().await;
    let id = note(&server, json!({"body": "Old"})).await;
    let response = server
        .upload_to(
            &server.owner,
            &format!("/notes/{id}"),
            ("a.txt", "text/plain", b"a".to_vec()),
            "k1",
            None,
        )
        .await;
    let version = response.json::<Value>().await.unwrap()["version"].clone();
    let trashed = server
        .api(
            &server.owner,
            "PATCH",
            &format!("/notes/{id}"),
            Some(json!({"version": version, "trashed": true})),
        )
        .await;
    // An edit of the note keeps its files.
    assert_eq!(trashed["files"][0]["name"], "a.txt");
    assert_eq!(
        get(&server, &server.owner, &format!("/notes/{id}/files/1"))
            .await
            .status(),
        200
    );
    let added = server
        .upload_to(
            &server.owner,
            &format!("/notes/{id}"),
            ("b.txt", "text/plain", b"b".to_vec()),
            "k2",
            None,
        )
        .await;
    assert_eq!(added.status(), 400);
    let (status, _) = delete(
        &server,
        &server.owner,
        &format!("/notes/{id}/files/1"),
        "k3",
    )
    .await;
    assert_eq!(status, 400);
}

#[tokio::test]
async fn a_note_upload_retried_after_the_limit_was_lowered_is_stored_once() {
    let server = Server::start().await;
    let id = note(&server, json!({"body": "Scan"})).await;
    let path = format!("/notes/{id}");
    let send = || {
        server.upload_to(
            &server.owner,
            &path,
            ("scan.bin", "application/octet-stream", vec![7u8; 2_000_000]),
            "k1",
            None,
        )
    };
    let (status, first) = status_and_body(send().await).await;
    assert_eq!(status, 200, "{first}");
    assert_eq!(set_limit(&server, &server.owner, json!(1)).await.0, 200);
    let (status, again) = status_and_body(send().await).await;
    assert_eq!(status, 200, "{again}");
    assert_eq!(again["files"], first["files"]);
    assert_eq!(again["version"], first["version"]);
    let added = note_actions(&server, id)
        .await
        .iter()
        .filter(|action| *action == "file_added")
        .count();
    assert_eq!(added, 1);
}

#[tokio::test]
async fn a_token_without_read_gets_a_receipt_for_a_note_file() {
    let server = Server::start().await;
    let writer = server.token("writer", "write");
    let id = note(&server, json!({"body": "Drop box"})).await;
    let (status, body) = status_and_body(
        server
            .upload_to(
                &writer,
                &format!("/notes/{id}"),
                ("a.txt", "text/plain", b"a".to_vec()),
                "w1",
                None,
            )
            .await,
    )
    .await;
    assert_eq!(status, 200);
    assert_eq!(body, json!({"id": id, "version": 2}));
}

#[tokio::test]
async fn no_edit_writes_the_files_of_a_note() {
    let server = Server::start().await;
    let id = note(&server, json!({"body": "Plain"})).await;
    let list = json!([{"id": 1, "name": "a.txt", "mime": "text/plain", "bytes": 1, "sha256": "0"}]);
    let client = reqwest::Client::new();
    let created = client
        .post(format!("{}/api/notes", server.url()))
        .bearer_auth(&server.owner)
        .header("Idempotency-Key", "k1")
        .json(&json!({"body": "With files", "files": list}))
        .send()
        .await
        .unwrap();
    assert_eq!(created.status(), 400);
    let edited = client
        .patch(format!("{}/api/notes/{id}", server.url()))
        .bearer_auth(&server.owner)
        .header("Idempotency-Key", "k2")
        .json(&json!({"version": 1, "files": list}))
        .send()
        .await
        .unwrap();
    assert_eq!(edited.status(), 400);
    let stored = server
        .api(&server.owner, "GET", &format!("/notes/{id}"), None)
        .await;
    assert_eq!(stored["note"]["files"], json!([]));
}
