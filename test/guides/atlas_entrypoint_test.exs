defmodule ExAtlas.Guides.AtlasEntrypointTest do
  # Runs the reference entrypoint (guides/scripts/atlas_entrypoint.sh) with
  # `sh`, a stub `aws` and a stub `curl` first on PATH, and a trainer that is a
  # few lines of shell. The stubs record their arguments, the way
  # translate_test.exs shims `curl`.
  use ExUnit.Case, async: true

  @script Path.expand("../../guides/scripts/atlas_entrypoint.sh", __DIR__)

  @secrets %{
    "AWS_ACCESS_KEY_ID" => "AKIAdistinct-key-id-4471",
    "AWS_SECRET_ACCESS_KEY" => "distinct-secret-access-9f3a7c",
    "AWS_SESSION_TOKEN" => "distinct-session-token-b81e55"
  }

  @stub """
  #!/bin/sh
  echo "$*" >> "$STUB_DIR/aws.log"
  # Skip global options so the subcommand is $1.
  if [ "$1" = "--endpoint-url" ]; then shift 2; fi
  [ "$1" = "s3" ] || exit 0
  case "$2" in
    sync)
      case "$3" in
        s3://*) [ -n "$STUB_FAIL_PULL" ] && { echo "stub: pull refused" >&2; exit 1; } ;;
        *) [ -n "$STUB_FAIL_PUSH" ] && { echo "stub: upload refused" >&2; exit 1; } ;;
      esac ;;
    cp)
      [ -n "$STUB_FAIL_CP" ] && { echo "stub: copy refused" >&2; exit 1; }
      cp "$3" "$STUB_DIR/uploaded.log" ;;
  esac
  exit 0
  """

  # Serves $STUB_SERVE for a download and keeps the file of an upload. A
  # failure prints what curl -fsS prints for an HTTP 403: no URL.
  @curl_stub """
  #!/bin/sh
  echo "$*" >> "$STUB_DIR/curl.log"
  out=
  upload=
  while [ "$#" -gt 0 ]; do
    case "$1" in
      -o) out=$2; shift 2 ;;
      -T) upload=$2; shift 2 ;;
      *) shift ;;
    esac
  done
  if [ -n "$upload" ]; then
    [ -n "$STUB_FAIL_PUT" ] && { echo "curl: (22) The requested URL returned error: 403" >&2; exit 22; }
    cp "$upload" "$STUB_DIR/uploaded.tar.gz"
    exit 0
  fi
  [ -n "$STUB_FAIL_GET" ] && { echo "curl: (22) The requested URL returned error: 403" >&2; exit 22; }
  if [ -n "$out" ]; then cp "$STUB_SERVE" "$out"; else cat "$STUB_SERVE"; fi
  """

  setup do
    dir = Path.join(System.tmp_dir!(), "atlas_ep_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)

    stub = Path.join(dir, "aws")
    File.write!(stub, @stub)
    File.chmod!(stub, 0o755)

    curl = Path.join(dir, "curl")
    File.write!(curl, @curl_stub)
    File.chmod!(curl, 0o755)

    {:ok, dir: dir}
  end

  # Runs the script and returns %{status, output, aws, uploaded_log}.
  defp run(dir, trainer, env) do
    base = [
      {"PATH", dir <> ":" <> System.get_env("PATH", "/usr/bin:/bin")},
      {"STUB_DIR", dir},
      {"ATLAS_TEST_LOG", Path.join(dir, "trainer.log")},
      {"ATLAS_DATASET_DIR", Path.join(dir, "data")},
      {"ATLAS_ARTIFACT_DIR", Path.join(dir, "artifacts")},
      {"ATLAS_LOG_FILE", Path.join(dir, "atlas.log")}
    ]

    {output, status} =
      System.cmd("sh", [@script | trainer], env: base ++ env, stderr_to_stdout: true)

    %{
      status: status,
      output: output,
      aws: read(Path.join(dir, "aws.log")),
      trainer: read(Path.join(dir, "trainer.log")),
      uploaded_log: read(Path.join(dir, "uploaded.log")),
      local_log: read(Path.join(dir, "atlas.log")),
      curl: read(Path.join(dir, "curl.log")),
      archive: nil
    }
  end

  defp read(path), do: if(File.exists?(path), do: File.read!(path), else: "")

  defp uris,
    do: [
      {"ATLAS_DATASET_URI", "s3://bkt/datasets/abc/"},
      {"ATLAS_ARTIFACT_URI", "s3://bkt/artifacts/run-1/"}
    ]

  defp marker_trainer(code \\ 0),
    do: ["sh", "-c", "echo TRAINER-RAN >> \"$ATLAS_TEST_LOG\"; exit #{code}"]

  # The merged order of aws calls and the trainer marker.
  defp timeline(r) do
    calls = String.split(r.aws, "\n", trim: true)
    {before_t, after_t} = Enum.split_while(calls, &String.contains?(&1, "s3://bkt/datasets"))
    {before_t, r.trainer =~ "TRAINER-RAN", after_t}
  end

  describe "the happy path" do
    test "pulls the dataset, runs the trainer, then syncs artifacts and copies the log", %{
      dir: dir
    } do
      r = run(dir, marker_trainer(), uris())

      assert r.status == 0
      assert {[pull], true, [push, cp]} = timeline(r)
      assert pull == "s3 sync s3://bkt/datasets/abc/ #{dir}/data"
      assert push == "s3 sync #{dir}/artifacts s3://bkt/artifacts/run-1/"
      assert cp == "s3 cp #{dir}/atlas.log s3://bkt/artifacts/run-1/atlas.log"
    end

    test "the log copied to S3 holds the trainer's stdout and stderr", %{dir: dir} do
      r = run(dir, ["sh", "-c", "echo OUT-LINE; echo ERR-LINE >&2"], uris())

      assert r.uploaded_log =~ "OUT-LINE"
      assert r.uploaded_log =~ "ERR-LINE"
      assert r.output =~ "OUT-LINE"
      assert r.output =~ "ERR-LINE"
    end

    test "an artifact URI without a trailing slash still puts atlas.log inside it", %{dir: dir} do
      r = run(dir, marker_trainer(), [{"ATLAS_ARTIFACT_URI", "s3://bkt/artifacts/run-1"}])

      assert r.aws =~ "s3 cp #{dir}/atlas.log s3://bkt/artifacts/run-1/atlas.log"
    end
  end

  describe "the exit code" do
    test "is the trainer's, and the artifacts still upload", %{dir: dir} do
      r = run(dir, marker_trainer(3), uris())

      assert r.status == 3
      assert {_, true, [push, _cp]} = timeline(r)
      assert push =~ "s3 sync #{dir}/artifacts s3://bkt/artifacts/run-1/"
    end

    test "a failed dataset pull exits non-zero and never runs the trainer", %{dir: dir} do
      r = run(dir, marker_trainer(), uris() ++ [{"STUB_FAIL_PULL", "1"}])

      assert r.status != 0
      refute r.trainer =~ "TRAINER-RAN"
      assert r.output =~ "dataset pull failed"
    end

    test "a failed pull still uploads the log, which explains it", %{dir: dir} do
      r = run(dir, marker_trainer(), uris() ++ [{"STUB_FAIL_PULL", "1"}])

      assert r.uploaded_log =~ "pull refused"
    end

    test "a failed artifact upload is printed and the trainer's code stands", %{dir: dir} do
      ok = run(dir, marker_trainer(0), uris() ++ [{"STUB_FAIL_PUSH", "1"}])
      assert ok.status == 0
      assert ok.output =~ "artifact upload failed"

      bad = run(dir, marker_trainer(7), uris() ++ [{"STUB_FAIL_PUSH", "1"}])
      assert bad.status == 7
    end

    test "a SIGTERM reaches the trainer and the artifacts still upload", %{dir: dir} do
      # The trainer signals the script (its parent), then waits to be killed.
      r = run(dir, ["sh", "-c", "kill -TERM $PPID; exec sleep 30"], uris())

      assert r.status == 143
      assert r.aws =~ "s3 sync #{dir}/artifacts s3://bkt/artifacts/run-1/"
      assert r.aws =~ "atlas.log"
    end
  end

  describe "optional pieces" do
    test "without ATLAS_DATASET_URI no dataset sync runs and the trainer does", %{dir: dir} do
      r = run(dir, marker_trainer(), [{"ATLAS_ARTIFACT_URI", "s3://bkt/artifacts/run-1/"}])

      assert r.status == 0
      assert r.trainer =~ "TRAINER-RAN"
      refute r.aws =~ "s3://bkt/datasets"
      refute r.aws =~ "#{dir}/data"
      assert r.aws =~ "s3 sync #{dir}/artifacts"
    end

    test "without ATLAS_ARTIFACT_URI nothing uploads", %{dir: dir} do
      r = run(dir, marker_trainer(), [{"ATLAS_DATASET_URI", "s3://bkt/datasets/abc/"}])

      assert r.status == 0
      assert r.aws =~ "s3 sync s3://bkt/datasets/abc/"
      refute r.aws =~ "artifacts"
      refute r.aws =~ "atlas.log"
    end

    test "with no trainer command it exits 2 and runs nothing", %{dir: dir} do
      r = run(dir, [], uris())

      assert r.status == 2
      assert r.output =~ "usage"
      assert r.aws == ""
    end
  end

  describe "AWS_ENDPOINT_URL_S3" do
    test "set: every aws call carries --endpoint-url and that URL", %{dir: dir} do
      r =
        run(dir, marker_trainer(), uris() ++ [{"AWS_ENDPOINT_URL_S3", "https://t3.storage.dev"}])

      calls = String.split(r.aws, "\n", trim: true)
      assert length(calls) == 3

      assert Enum.all?(
               calls,
               &String.starts_with?(&1, "--endpoint-url https://t3.storage.dev s3 ")
             )
    end

    test "unset: no call carries --endpoint-url", %{dir: dir} do
      r = run(dir, marker_trainer(), uris())

      calls = String.split(r.aws, "\n", trim: true)
      assert length(calls) == 3
      refute r.aws =~ "--endpoint-url"
    end
  end

  @get_sig "getsig-5d0c91"
  @get_url "https://bkt.s3.amazonaws.com/d.tar.gz?X-Amz-Signature=#{@get_sig}"

  # A dataset archive in `dir`, built by the system tar; `gzip: false` leaves
  # it uncompressed.
  defp dataset_archive(dir, opts \\ []) do
    src = Path.join(dir, "src")
    File.mkdir_p!(Path.join(src, "shards"))
    File.write!(Path.join(src, "train.txt"), "DATASET-ROW-1")
    File.write!(Path.join([src, "shards", "s0.txt"]), "SHARD-0")
    archive = Path.join(dir, "dataset.tar")
    flags = if Keyword.get(opts, :gzip, true), do: "-czf", else: "-cf"
    {_, 0} = System.cmd("tar", [flags, archive, "-C", src, "."])
    archive
  end

  defp reads_dataset,
    do: [
      "sh",
      "-c",
      "cat \"$ATLAS_DATASET_DIR/train.txt\" \"$ATLAS_DATASET_DIR/shards/s0.txt\" >> \"$ATLAS_TEST_LOG\""
    ]

  describe "ATLAS_DATASET_URL" do
    test "downloads the archive and the trainer sees its files", %{dir: dir} do
      r =
        run(dir, reads_dataset(), [
          {"ATLAS_DATASET_URL", @get_url},
          {"STUB_SERVE", dataset_archive(dir)}
        ])

      assert r.status == 0
      assert r.trainer == "DATASET-ROW-1SHARD-0"
      assert r.curl =~ @get_url
      assert r.aws == ""
    end

    test "an uncompressed tar works too", %{dir: dir} do
      r =
        run(dir, reads_dataset(), [
          {"ATLAS_DATASET_URL", @get_url},
          {"STUB_SERVE", dataset_archive(dir, gzip: false)}
        ])

      assert r.status == 0
      assert r.trainer == "DATASET-ROW-1SHARD-0"
    end

    test "leaves no download file beside the dataset", %{dir: dir} do
      run(dir, reads_dataset(), [
        {"ATLAS_DATASET_URL", @get_url},
        {"STUB_SERVE", dataset_archive(dir)}
      ])

      assert dir |> Path.join("data") |> File.ls!() |> Enum.sort() == ["shards", "train.txt"]
    end

    test "a download that is not a tar archive exits non-zero and runs no trainer", %{dir: dir} do
      junk = Path.join(dir, "junk")
      File.write!(junk, "<Error><Code>AccessDenied</Code></Error>")

      r = run(dir, marker_trainer(), [{"ATLAS_DATASET_URL", @get_url}, {"STUB_SERVE", junk}])

      assert r.status != 0
      refute r.trainer =~ "TRAINER-RAN"
      assert r.output =~ "dataset pull failed (tar exit"
    end

    test "with ATLAS_DATASET_URI set too, only aws pulls and the URL is ignored", %{dir: dir} do
      r =
        run(dir, marker_trainer(), [
          {"ATLAS_DATASET_URI", "s3://bkt/datasets/abc/"},
          {"ATLAS_DATASET_URL", @get_url},
          {"STUB_SERVE", dataset_archive(dir)}
        ])

      assert r.status == 0
      assert r.aws =~ "s3 sync s3://bkt/datasets/abc/"
      assert r.curl == ""
      assert r.output =~ "ATLAS_DATASET_URL ignored: ATLAS_DATASET_URI is set"
      refute r.output =~ @get_sig
    end
  end

  describe "credentials" do
    @creds Map.to_list(@secrets)

    defp assert_no_secret_anywhere(r) do
      for {_name, secret} <- @secrets do
        for {where, text} <- [
              output: r.output,
              aws_args: r.aws,
              local_log: r.local_log,
              uploaded_log: r.uploaded_log
            ] do
          refute text =~ secret, "#{where} leaked #{secret}"
        end
      end
    end

    test "control: a trainer that prints a secret shows up in every place we search", %{dir: dir} do
      r = run(dir, ["sh", "-c", "echo $AWS_SECRET_ACCESS_KEY"], uris() ++ @creds)

      secret = @secrets["AWS_SECRET_ACCESS_KEY"]
      assert r.output =~ secret
      assert r.local_log =~ secret
      assert r.uploaded_log =~ secret
    end

    test "the script prints none of the three credentials on success", %{dir: dir} do
      assert_no_secret_anywhere(run(dir, marker_trainer(), uris() ++ @creds))
    end

    test "nor when the pull fails", %{dir: dir} do
      r = run(dir, marker_trainer(), uris() ++ @creds ++ [{"STUB_FAIL_PULL", "1"}])
      assert r.status != 0
      assert_no_secret_anywhere(r)
    end

    test "nor when the upload and the log copy fail, or the endpoint is set", %{dir: dir} do
      env =
        uris() ++
          @creds ++
          [{"STUB_FAIL_PUSH", "1"}, {"STUB_FAIL_CP", "1"}, {"AWS_ENDPOINT_URL_S3", "https://e"}]

      r = run(dir, marker_trainer(5), env)
      assert r.status == 5
      assert r.output =~ "artifact upload failed"
      assert_no_secret_anywhere(r)
    end
  end
end
