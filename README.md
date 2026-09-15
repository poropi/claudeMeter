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

claudeMeter はサーバーが返した実測値を使う。Claude Code は statusLine スクリプトの
stdin JSON に `rate_limits` を渡しており、これは `/usage` が表示するものと同じ値である。

```json
"rate_limits": {
  "five_hour": { "used_percentage": 23.5, "resets_at": 1738425600 },
  "seven_day": { "used_percentage": 41.2, "resets_at": 1738857600 }
}
```

## 構成

| | |
|---|---|
| 収集 | `collector/claudemeter_collector.py` を `~/.claude/statusline.py` に差し込む。値が変化したときだけ `~/.claude/claudemeter/samples.jsonl` に 1 行追記する |
| 表示 | `Sources/ClaudeMeter/` — SwiftUI `MenuBarExtra` の常駐アプリ。外部ライブラリ・常駐デーモンなし |
| 到達履歴 | `~/.claude/projects/**/*.jsonl` に残る 429 の `quotaLimits` を走査し、実際に上限へ当たった時刻を出す。ファイルごとに走査済みオフセットを覚えるので 2 回目以降は数十 ms |

## セットアップ

```bash
python3 scripts/install-collector.py     # ~/.claude/statusline.py に収集フックを差し込む
bash scripts/build-app.sh                # ~/Applications/ClaudeMeter.app を作る
open ~/Applications/ClaudeMeter.app
```

`install-collector.py` は初回に `~/.claude/statusline.py.bak.claudemeter` へバックアップを取る。
収集ロジックを更新したら再実行すれば差し替わる。外すのは `--uninstall`。

ログイン時に自動起動するには、システム設定 → 一般 → ログイン項目に `ClaudeMeter.app` を追加する。

### サンプリング密度を上げる（任意）

statusLine は既定ではイベント時（各ターンなど）にしか走らない。長いツール実行中も追従させたいなら
`~/.claude/settings.json` の `statusLine` に `refreshInterval` を足す。

```json
"statusLine": { "type": "command", "command": "python3 ~/.claude/statusline.py", "refreshInterval": 30 }
```

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
```

`CLAUDEMETER_DIR` で読み込み元を差し替えられる（合成データでの検証用）。

## 制約

- `rate_limits` は **Claude.ai Pro / Max 契約**で、かつセッションの最初の API 応答後にのみ来る
- **Claude Code のセッションが動いている間しかサンプリングできない。** セッション外は最後の値と
  リセットまでのカウントダウンを表示する
- リセット時刻を過ぎた窓は 0% として扱う（Claude Code 自身も当該キーを落とす）。
  次の窓の開始は最初の送信時なので、リセット時刻は再取得まで分からない
- サーバーが返す値はおおむね整数刻みなので、バーンレートは直近 45 分で出せないときは
  窓全体の平均に落ちる
