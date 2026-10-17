# Object storage: Tigris, AWS S3 and MinIO

`ExAtlas.S3` reads and writes objects in any S3-compatible bucket from your
app, with no second S3 library. This guide sets up a bucket and a key on
each store, then hands out presigned links.

```elixir
s3 = ExAtlas.S3.config!(bucket: System.fetch_env!("BUCKET_NAME"))
:ok = ExAtlas.S3.put(s3, "events/1/thumb.jpg", jpeg, content_type: "image/jpeg")
{:ok, url} = ExAtlas.S3.presign(s3, :get, "events/1/thumb.jpg", expires_in: 3600)
```

`config!/1` reads the endpoint, region and keys from the `AWS_*` variables
when you leave them out. An empty variable counts as unset.

## Tigris on Fly

From the app's directory, `fly storage create` makes a bucket and sets four
secrets on the app: `BUCKET_NAME`, `AWS_ENDPOINT_URL_S3`, `AWS_ACCESS_KEY_ID`
and `AWS_SECRET_ACCESS_KEY`. Fly shows the keys once; save them then.

```elixir
s3 = ExAtlas.S3.config!(bucket: System.fetch_env!("BUCKET_NAME"))
# endpoint from AWS_ENDPOINT_URL_S3, region "auto"
```

Keep the default `path_style: false`. Tigris serves buckets made since
February 2025 only on the bucket's own host name.

## AWS S3

Set `AWS_REGION`, `AWS_ACCESS_KEY_ID` and `AWS_SECRET_ACCESS_KEY`, and leave
the endpoint out. ExAtlas then calls `https://s3.<region>.amazonaws.com`.

```elixir
s3 = ExAtlas.S3.config!(bucket: "acme-media", region: "eu-west-1")
```

## MinIO on your own network

MinIO serves buckets in the path unless you give it a domain for virtual
hosts, so set `path_style: true`.

```elixir
s3 =
  ExAtlas.S3.config!(
    bucket: "media",
    endpoint: "http://minio.internal:9000",
    path_style: true
  )
```

A store with its own certificate authority takes it through `req_options`:
`req_options: [connect_options: [transport_opts: [cacertfile: "/etc/ssl/minio-ca.pem"]]]`.

## One bucket per purpose, one key per bucket

Give each kind of data its own bucket (event pictures, models, backups) and
each bucket its own key. A leaked or buggy key then reaches one bucket, and
a `delete_prefix/2` with the wrong folder cannot touch another bucket's
objects.

- **Tigris.** In the Tigris dashboard, create an access key with the
  ReadWrite role on the selected bucket only. Editor also lets the key change
  the bucket's settings, and Admin reaches every bucket.
- **AWS S3.** Give the key's IAM user only this policy, with your bucket's
  name in both ARNs:

  ```json
  {
    "Version": "2012-10-17",
    "Statement": [
      {
        "Effect": "Allow",
        "Action": ["s3:ListBucket", "s3:ListBucketMultipartUploads"],
        "Resource": "arn:aws:s3:::acme-media"
      },
      {
        "Effect": "Allow",
        "Action": [
          "s3:GetObject",
          "s3:PutObject",
          "s3:DeleteObject",
          "s3:AbortMultipartUpload",
          "s3:ListMultipartUploadParts"
        ],
        "Resource": "arn:aws:s3:::acme-media/*"
      }
    ]
  }
  ```

- **MinIO.** The same policy works. Save it as `media-rw.json`, then:

  ```sh
  mc admin policy create local media-rw media-rw.json
  mc admin user add local media-app <a long random secret>
  mc admin policy attach local media-rw --user media-app
  ```

## Unfinished multipart uploads

A large upload goes up in parts. ExAtlas aborts the upload when a step fails,
but the abort is one more request and can fail too. The parts then stay in
the bucket, bill as storage, and never show in a listing. A rule that aborts
uploads left unfinished for a day clears them.

- **AWS S3.** Save this as `lifecycle.json` and apply it once per bucket:

  ```json
  {
    "Rules": [
      {
        "ID": "abort-unfinished-uploads",
        "Status": "Enabled",
        "Filter": {"Prefix": ""},
        "AbortIncompleteMultipartUpload": {"DaysAfterInitiation": 1}
      }
    ]
  }
  ```

  ```sh
  aws s3api put-bucket-lifecycle-configuration --bucket acme-media \
    --lifecycle-configuration file://lifecycle.json
  ```

- **MinIO.** The server expires unfinished uploads itself, after 24 hours by
  default (`stale_uploads_expiry` under `mc admin config get local api`).
  Keep that, and add no expiry rule: `mc ilm rule add --expire-days` also
  deletes finished objects.
- **Tigris.** Tigris accepts the same lifecycle call through its S3 API, but
  its docs do not say it honours `AbortIncompleteMultipartUpload`. Apply the
  rule with `--endpoint-url https://t3.storage.dev`, then check a day later
  that `aws s3api list-multipart-uploads --bucket <bucket> --endpoint-url
  https://t3.storage.dev` lists nothing old.

## Presigned links

A presigned link lets a browser or a device GET or PUT one object until it
expires, with no key of its own. ExAtlas signs it in memory and sends no
request.

```elixir
{:ok, url} = ExAtlas.S3.presign(s3, :get, "clips/42.mp4", expires_in: 900)
{:ok, upload} = ExAtlas.S3.presign(s3, :put, "uploads/abc.jpg", expires_in: 300)
```

- `expires_in:` is required, from 1 second to 604,800 (seven days, the most
  SigV4 allows). Give the shortest time the client needs: anyone holding the
  link can use it until then, and you cannot revoke one link alone. Rotating
  the key revokes every link it signed.
- A PUT link takes any body, of any size the store allows, with the content
  type its holder picks. Never hand one out for a bucket a website serves:
  the holder can upload HTML. Check the object after the client says it
  uploaded, with `head/2`. The store refuses an added `x-amz-acl` or other
  `x-amz-*` header, since the link does not sign one.
- The link carries the access key id, never the secret key.
