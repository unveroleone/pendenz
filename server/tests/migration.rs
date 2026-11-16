// Migration 0008 on a database with images and files, as a server before it left them: the
// images keep their IDs, the files move up, and the server goes on from there.
mod support;

use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use sqlx::{SqlitePool, migrate::Migrator};
use support::*;

fn sha256(data: &[u8]) -> String {
    Sha256::digest(data)
        .iter()
        .map(|byte| format!("{byte:02x}"))
        .collect()
}

async fn add_item(db: &SqlitePool, title: &str) -> i64 {
    sqlx::query("UPDATE meta SET value = value + 1 WHERE key = 'seq'")
        .execute(db)
        .await
        .unwrap();
    sqlx::query_scalar(
        "INSERT INTO items(title, position, agent_stage, created_via, seq, created_by, updated_by) \
         SELECT ?, 1, 'none', 'app', value, 'owner', 'owner' FROM meta WHERE key = 'seq' \
         RETURNING id",
    )
    .bind(title)
    .fetch_one(db)
    .await
    .unwrap()
}

async fn add_bytes(db: &SqlitePool, image: bool, item: i64, data: &[u8]) -> i64 {
    let sql = if image {
        "INSERT INTO item_images(item_id, data) VALUES (?, ?) RETURNING id"
    } else {
        "INSERT INTO item_files(item_id, data) VALUES (?, ?) RETURNING id"
    };
    sqlx::query_scalar(sql)
        .bind(item)
        .bind(data)
        .fetch_one(db)
        .await
        .unwrap()
}

async fn set_list(db: &SqlitePool, images: bool, item: i64, list: Value) {
    let sql = if images {
        "UPDATE items SET images = ? WHERE id = ?"
    } else {
        "UPDATE items SET files = ? WHERE id = ?"
    };
    sqlx::query(sql)
        .bind(list.to_string())
        .bind(item)
        .execute(db)
        .await
        .unwrap();
}

fn image(id: i64, data: &[u8]) -> Value {
    json!({"id": id, "mime": "image/png", "width": 1, "height": 1, "bytes": data.len(), "sha256": sha256(data)})
}

async fn get(server: &Server, path: &str) -> reqwest::Response {
    reqwest::Client::new()
        .get(format!("{}/api{path}", server.url()))
        .bearer_auth(&server.owner)
        .send()
        .await
        .unwrap()
}

#[tokio::test]
async fn images_and_files_become_one_list() {
    let dir = scratch_dir();
    // The migrations before this one, as the database had them.
    let before = dir.join("migrations");
    std::fs::create_dir_all(&before).unwrap();
    for entry in std::fs::read_dir(concat!(env!("CARGO_MANIFEST_DIR"), "/migrations")).unwrap() {
        let path = entry.unwrap().path();
        let name = path.file_name().unwrap().to_str().unwrap().to_owned();
        if name.as_str() < "0008" {
            std::fs::copy(&path, before.join(name)).unwrap();
        }
    }
    let url = format!("sqlite://{}/pendenz.db?mode=rwc", dir.display());
    let db = SqlitePool::connect(&url).await.unwrap();
    Migrator::new(before.as_path())
        .await
        .unwrap()
        .run(&db)
        .await
        .unwrap();

    let car = add_item(&db, "Car").await;
    let tax = add_item(&db, "Tax").await;
    let trip = add_item(&db, "Trip").await;
    let pdf = b"%PDF-1.7 offer".to_vec();
    let text = b"Passport\n".to_vec();
    let first = add_bytes(&db, true, car, &PNG).await;
    let second = add_bytes(&db, true, car, &PNG).await;
    let third = add_bytes(&db, true, tax, &PNG).await;
    // A removed image leaves its ID behind; no file may get it.
    let removed = add_bytes(&db, true, tax, &PNG).await;
    sqlx::query("DELETE FROM item_images WHERE id = ?")
        .bind(removed)
        .execute(&db)
        .await
        .unwrap();
    let offer = add_bytes(&db, false, car, &pdf).await;
    let list = add_bytes(&db, false, trip, &text).await;
    assert_eq!(
        (first, second, third, removed, offer, list),
        (1, 2, 3, 4, 1, 2)
    );
    // The second image comes first on the car, so the order is kept as it was.
    set_list(
        &db,
        true,
        car,
        json!([image(second, &PNG), image(first, &PNG)]),
    )
    .await;
    set_list(&db, true, tax, json!([image(third, &PNG)])).await;
    set_list(&db, false,
        car,
        json!([{"id": offer, "name": "Offer.pdf", "mime": "application/pdf", "bytes": pdf.len(), "sha256": sha256(&pdf), "upload_id": "u1"}]),
    )
    .await;
    set_list(&db, false,
        trip,
        json!([{"id": list, "name": "List.txt", "mime": "text/plain", "bytes": text.len(), "sha256": sha256(&text)}]),
    )
    .await;
    db.close().await;

    // The server runs 0008 when it starts.
    let server = Server::start_in(dir.clone()).await;
    let item = |id: i64| {
        let server = &server;
        async move {
            server
                .api(&server.owner, "GET", &format!("/items/{id}"), None)
                .await["item"]
                .clone()
        }
    };

    let car_item = item(car).await;
    let ids: Vec<i64> = car_item["files"]
        .as_array()
        .unwrap()
        .iter()
        .map(|file| file["id"].as_i64().unwrap())
        .collect();
    assert_eq!(ids, [2, 1, 5], "images keep their IDs, files move up by 4");
    assert_eq!(car_item["files"][0]["name"], "Image.png");
    assert_eq!(car_item["files"][0]["width"], 1);
    assert_eq!(car_item["files"][0]["sha256"], sha256(&PNG));
    assert_eq!(car_item["files"][2]["name"], "Offer.pdf");
    assert_eq!(car_item["files"][2]["upload_id"], "u1");
    assert!(car_item["files"][2].get("width").is_none());
    let old_images: Vec<i64> = car_item["images"]
        .as_array()
        .unwrap()
        .iter()
        .map(|image| image["id"].as_i64().unwrap())
        .collect();
    assert_eq!(old_images, [2, 1], "an app of 0.2.0 still sees its images");
    assert_eq!(item(tax).await["files"][0]["id"], 3);
    assert_eq!(item(trip).await["files"][0]["id"], 6);

    // The bytes are found under the new IDs, by either route for a picture.
    let response = get(&server, &format!("/items/{car}/files/5")).await;
    assert_eq!(response.status(), 200);
    assert_eq!(response.bytes().await.unwrap().to_vec(), pdf);
    let response = get(&server, &format!("/items/{car}/images/1")).await;
    assert_eq!(response.status(), 200);
    assert_eq!(response.bytes().await.unwrap().to_vec(), PNG);
    let response = get(&server, &format!("/items/{trip}/files/6")).await;
    assert_eq!(response.bytes().await.unwrap().to_vec(), text);
    assert_eq!(
        get(&server, &format!("/items/{trip}/images/6"))
            .await
            .status(),
        404,
        "a file that is no picture is no image"
    );

    // The next file goes above every ID given before.
    let response = server
        .upload(
            &server.owner,
            trip,
            ("More.txt", "text/plain", b"x".to_vec()),
            "m1",
            None,
        )
        .await;
    assert!(response.status().is_success());
    let files = item(trip).await["files"].clone();
    assert_eq!(files[1]["id"], 7);

    // The old column and table are gone.
    let db = SqlitePool::connect(&url).await.unwrap();
    let left: i64 = sqlx::query_scalar(
        "SELECT (SELECT count(*) FROM pragma_table_info('items') WHERE name = 'images') \
         + (SELECT count(*) FROM sqlite_master WHERE name = 'item_images')",
    )
    .fetch_one(&db)
    .await
    .unwrap();
    assert_eq!(left, 0);
}
