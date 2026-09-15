# claudeMeter

Claude Code の **5時間制限**と**週間制限（7日）**の残量を、macOS のメニューバーに常駐表示する。

```
┌─ menu bar ────────────────────────┐
│  ◔23% ◑41%                        │
└───────────────────────────────────┘
```

クリックすると消費率・リセットまでの残り時間・バーンレート・予測枯渇時刻・直近に上限へ到達した日時が出る。

## なぜ作るか

`ccusage` や `claude-monitor` はローカル JSONL のトークン数から 5時間ブロックを**推定**する。
トークン量と実際のクォータ消費は比例しない（モデル・キャッシュ読み・effort で係数が違う）し、
週間制限は扱っていない。

claudeMeter はサーバーが返した実測値を使う。`claude` に control_request `get_usage` を
投げると、`/usage` が出すのと同じ残量がそのまま返る。

```json
{"type":"control_request","request_id":"1",
 "request":{"subtype":"get_usage","skip_behaviors":true}}
```
```json
"rate_limits": {
  "five_hour": { "utilization": 23, "resets_at": "2026-09-15T05:40:00+00:00" },
  "seven_day": { "utilization": 41, "resets_at": "2026-09-19T23:00:00+00:00" }
}
```

`skip_behaviors` は「プラン残量だけが必要な usage meter 向け」と説明されているオプションで、
7 日分のトランスクリプト走査を省く。プロンプトを送らないのでクォータは消費しない
（`total_cost_usd` は 0 のまま）。

## 構成

| | |
|---|---|
| 取得 | `claude` を 1 プロセス常駐させ、30 秒ごとに control_request `get_usage` を投げる。プロンプトを送らないのでクォータは減らない |
| 収集 (副) | `collector/claudemeter_collector.py` を `~/.claude/statusline.py` に差し込む。ターミナルで作業している間だけ動く保険 |
| 表示 | `Sources/ClaudeMeter/` — SwiftUI `MenuBarExtra` の常駐アプリ。外部ライブラリ・常駐デーモンなし |
| 到達履歴 | `~/.claude/projects/**/*.jsonl` に残る 429 の `quotaLimits` を走査し、実際に上限へ当たった時刻を出す。ファイルごとに走査済みオフセットを覚えるので 2 回目以降は数十 ms |

## セットアップ

```bash
bash scripts/build-app.sh                # ~/Applications/ClaudeMeter.app を作る
open ~/Applications/ClaudeMeter.app
```

これだけで動く。`claude` の場所は自分で探す（対話シェルの PATH → nvm の各バージョン →
`~/.claude/local` → homebrew の順に見て、**バージョンが一番新しいもの**を選ぶ。`get_usage` に
応えるのは 2.0 以降で、homebrew に 1.x が残っていることがあるため）。
明示するなら `CLAUDEMETER_CLAUDE_BIN`。取得間隔は `CLAUDEMETER_POLL_SECONDS`（既定 30 秒）。

### statusLine の収集フック（任意）

```bash
python3 scripts/install-collector.py     # ~/.claude/statusline.py に収集フックを差し込む
```

ターミナルで Claude Code を使っている間だけ、statusLine の stdin から同じ値を拾って
samples.jsonl に足す。**入れなくても表示は動く**（上の常駐取得が主で、こちらは保険）。
`install-collector.py` は初回に `~/.claude/statusline.py.bak.claudemeter` へバックアップを取る。
外すのは `--uninstall`。

### ログイン時に自動起動する

メニューの「ログイン時に起動」をオンにする。GUI を開かずに切り替えるなら:

```bash
~/Applications/ClaudeMeter.app/Contents/MacOS/ClaudeMeter --login-item register    # 登録
~/Applications/ClaudeMeter.app/Contents/MacOS/ClaudeMeter --login-item status      # 確認
~/Applications/ClaudeMeter.app/Contents/MacOS/ClaudeMeter --login-item unregister  # 解除
```

登録されるのは**そのとき起動している `.app` のパス**なので、`.app` を移動したら登録し直す。
macOS が承認を求める状態（`要承認`）になったら、メニューの「設定を開く」からログイン項目のペインへ飛べる。

## 確認

GUI を開かずに現在値を見る:

```bash
~/Applications/ClaudeMeter.app/Contents/MacOS/ClaudeMeter --dump
```

```
5時間制限  █████░░░░░░░░░░░░░░░  23%
  リセットまで 3:54  (14:40)

週間制限 (7日)  ███████░░░░░░░░░░░░░  35%
  リセットまで 4日 21:14  (9/20(日) 8:00)

バーンレート  12.0 %/h
予測枯渇      このペースなら到達せず
直近の到達    9/14 15:54  (5時間制限)
取得経路      ライブ (claude get_usage)
最終更新      14:45
サンプル数    32
```

`--dump` は起動時に 1 回サーバーへ取りに行くので、「今ライブで取れているか」もここで分かる。
取得経路の切り分けは `--probe`（どの `claude` を選んだか、何が返ったか）。
`CLAUDEMETER_DIR` で読み込み元を差し替えられる（合成データでの検証用）。

## 制約

- 残量が返るのは **Claude.ai Pro / Max / Team 契約**のとき。API キー・Bedrock・Vertex では
  `rate_limits_available` が false になり、その旨をメニューに出す
- `get_usage` は **Experimental**（`claude` 側のコメントどおり、応答の形は変わりうる）。
  取れなくなったら statusLine 経由の収集に落ちる
- サーバーが返す値はおおむね整数刻みなので、バーンレートは直近 45 分で出せないときは
  窓全体の平均に落ちる
- `claude` の常駐プロセスが 1 つ増える（アイドル。`--settings '{"disableAllHooks":true}'` を
  渡すので、ユーザーのフックは起こさない）
