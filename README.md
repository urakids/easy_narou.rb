# narou.rb を wslc で起動する

Windows PowerShell 5.1 / PowerShell 7 と、WSL 3.0系の `wslc.exe` を使用します。
Docker Desktop、Compose、別途のRuby/Javaインストールは不要です。
`Fetch`（イメージがないときの `Start` による自動取得を含む）はPowerShellと標準の.NET機能で実行します。
Pythonや外部のtarコマンドも不要です。
起動・取得・検証・tar作成はすべて `narou.ps1` 1ファイルに含まれます。
`narou.bat` はそのスクリプトを呼び出すダブルクリック用の補助ファイルです。

## 起動

`narou.bat` をダブルクリックするか、このフォルダーで以下を実行します。

```powershell
.\narou.bat
```

初回やイメージ削除後は、`Start` がイメージの有無を確認し、存在しなければ
`Fetch` と同じWindows側の取得・取り込み処理を自動実行して、そのままコンテナーを起動します。
イメージがあれば取得せずに使用します。取得に失敗した場合は起動せず、エラーで終了します。
既定のイメージは `kokotaro/narou:latest` です。
起動後、Web UIがHTTP応答を返すことを確認して、既定のブラウザーで
<http://localhost:9200/> を自動的に開きます。起動待ちは最大約30秒です。
既存コンテナーでも同様に開きます。ポートを変更している場合は、実際の公開ポートを使用します。
Web UIが応答しない場合はエラーで終了し、ブラウザーは開きません。
小説と設定はスクリプトと同じ場所の `novel` フォルダーに保存されます。
イメージに含まれる `init.sh` が初期設定を行うため、通常は手動での `narou init` は不要です。

PowerShellスクリプトを直接実行する場合:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\narou.ps1 Start
```

`ExecutionPolicy Bypass` はこのプロセスだけに適用されます。

## 操作

```powershell
.\narou.bat Stop
.\narou.bat Start
.\narou.bat Status
.\narou.bat Logs
```

`Start` は既存コンテナーがあれば再利用します。`Status` は状態、ポート、マウントを含むJSONを表示します。
`Logs` は直近100行を表示します。
Windows起動時の自動起動は設定しません。必要なときに `Start` を実行してください。

保存先・ポートを変えて初めて起動する場合:

```powershell
.\narou.bat Start -DataDir "F:\My Novels" -Port 9300 -WebSocketPort 9301
```

Web UIは <http://localhost:9300/> になります。9201（変更例では9301）はWebSocket用です。
2つのポートは別々に指定し、どちらも空いている番号を使用してください。
公開先は `127.0.0.1` です。同じPCからアクセスします。
複数環境を使う場合は、異なる `-Name`・保存先・ポートを指定してください。
既定のコンテナー名は `narou-wslc` です。名前を変えた場合は停止などにも同じ `-Name` を指定します。

## イメージ更新・設定変更

```powershell
.\narou.bat Remove
.\narou.bat Start
```

`Remove` はコンテナーを停止・削除した後、そのコンテナーが使用していたイメージIDを指定して削除します。
コンテナーが存在しない場合は `-Image` の値（既定は `kokotaro/narou:latest`）を削除対象にします。
Windows側の小説データと取得済みのtarファイルは残ります。
別コンテナーで使用中などの理由でイメージを削除できない場合は、強制削除せずエラーを表示します。
コンテナーの削除が済んでいても、イメージ削除に失敗した場合の終了コードは1です。
保存先・ポート・イメージの変更も、`Remove` 後の `Start` で指定します。
`Pull` だけでは既存コンテナーのイメージは切り替わりません。
タグを固定するなら `Pull` と `Start` の両方に `-Image kokotaro/narou:タグ名` を付けてください。

## 起動できない場合

### Docker HubへのTLS接続がタイムアウトする場合

`net/http: TLS handshake timeout` はイメージを取得する通信中のエラーです。
Windows側ではDocker Hubに接続できるのにwslc側で失敗する場合、以下を実行してください。

```powershell
.\narou.bat Fetch
.\narou.bat Start
```

`Fetch` はWindows側のHTTPS通信で公開イメージを取得し、SHA256を検証して
`narou-image-latest.tar` を作成します。そのファイルを `wslc load` で取り込みます。
Docker Desktopの起動や、WSL全体のネットワーク設定変更は不要です。
ダウンロードとtar作成中は数GB程度の空き容量を確保してください。
完了したtarは再読み込みやバックアップ用に残します。不要なら削除できます。
タグ指定には `Fetch -Image kokotaro/narou:タグ名` を使います。
既存コンテナーの更新は `Remove` → `Start` で行えます。イメージがない場合の `Fetch` は自動実行されます。
明示的に取得する場合は `Remove` → `Fetch` → `Start` の順です。
取得済みtarから再取り込みする場合は、`Remove` 後に以下を実行します。

```powershell
wslc load --input .\narou-image-latest.tar
.\narou.bat Start
```

Windows側でも通信が失敗する場合は、VPN・プロキシ・ファイアウォールなどの確認が必要です。
次のコマンドで `401 Unauthorized` が返れば、レジストリへのTLS接続自体は成功しています。
この401は認証前の正常な応答です。

```powershell
curl.exe --head --connect-timeout 15 --max-time 25 https://registry-1.docker.io/v2/
```

### その他のエラー

`certificate verify failed (unable to get local issuer certificate)` が出る場合、
この環境ではNortonのHTTPS検査が提示する証明書をコンテナーが信頼していないことが原因でした。
`Start` はWindowsの信頼済みルートストアにある、有効期限内の
`Norton Web/Mail Shield Root` を自動でコンテナーのCAストアへ追加します。
証明書の公開データは小説保存先の `.ca-certificates` に保存します。秘密鍵は取得しません。
公開CAの既存ストアとTLS検証はそのまま使用します。

すでに起動中のコンテナーに適用してWebサーバーも再起動する場合:

```powershell
.\narou.bat FixCertificates
```

この操作はコンテナーを再起動するため、進行中の処理があれば終わってから実行してください。
Norton以外の証明書は自動追加しません。

```powershell
wsl --version
wslc version
wslc container list --all
```

`wslc.exe` が見つからなければ `wsl --update` を実行し、ターミナルを開き直してください。
ランタイム側の問題はスクリプトでも終了コード1として報告します。
Web UIが開かないときは `Logs` と `Status` を確認してください。
既存データを使う場合、narouの `server-bind` 設定が `0.0.0.0` になっているかも確認してください。

2026-10-05、WSL 3.0.1の実環境で、wslcによる直接取得のTLSタイムアウトを再現しました。
Windows側での `Fetch` → `wslc load` → `Start` は成功し、Web UIのHTTP 200応答を確認しました。
Pythonを廃止したPowerShell版でも、全17レイヤーの取得・SHA256検証・.NETによるtar作成・`wslc load` の成功を確認済みです。
起動ログと、実行中のコンテナーを再利用する処理も確認済みです。
NortonのルートCA追加後、Rubyによる `ncode.syosetu.com` への接続で証明書チェーンの検証成功も確認しました。
指定された <https://ncode.syosetu.com/n2710db/> について、Narou本体の
`get_latest_table_of_contents` で小説名と662話の目次を取得・解析できました。
この検証では本文全話の取得やEPUB変換は実行していません。
PowerShellの構文チェック、および模擬呼び出しによる無関係なコンテナーの保護・データを残す削除の確認も完了しています。

## 参照

- 公開イメージと起動設定: <https://hub.docker.com/r/kokotaro/narou>
- イメージ作者によるDockerfile・初期化処理の説明: <https://qiita.com/kokotaro%40github/items/5c8da7281407b7484507>
- WSL 3.0.1: <https://github.com/microsoft/WSL/releases/tag/3.0.1>
- Registry HTTP API: <https://distribution.github.io/distribution/spec/api/>
