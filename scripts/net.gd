extends Node
## ─────────────────────────────────────────────
## Net(ネットワーク係)
## ─────────────────────────────────────────────
## オンラインで一緒に遊ぶための仕組みをまとめたスクリプトです。
## project.godot の [autoload] に登録しているので、
## どのスクリプトからでも「Net.〇〇」と書くだけで使えます。
##
## しくみのざっくり説明:
##   ・「ホスト」= ルームを作る人。ゲームの進行(点数・タイマーなど)を決める係。
##   ・「ゲスト」= パスワードを入れて、ホストのルームに入る人。
##   ・パソコンやスマホどうしは WebRTC という通信方法でつながります(くわしくは room.gd)。
##   ・各プレイヤーには「ピアID」という番号がつきます。ホストはいつも 1 番です。
##
## RPC(アールピーシー)とは:
##   「ほかのパソコンにある同じ関数を呼び出す」機能です。
##   関数の上に @rpc と書くと、その関数を .rpc() で全員に、
##   .rpc_id(番号) で特定の人だけに実行してもらえます。

## プレイヤーの一覧が変わったときに知らせる合図(シグナル)
signal players_changed
## 接続に失敗したとき・切れたときに知らせる合図
signal connection_problem(message: String)

## ルームができたときの合図(パスワードつき)
signal room_ready(code: String)

## 一つのルームに入れる最大人数(ホストをのぞく)
const MAX_CLIENTS := 7

const RoomScript = preload("res://scripts/room.gd")
var room: Node              # ルームとパスワードの係(room.gd)
var room_code := ""         # 今いるルームのパスワード

## プレイヤーの色。入った順に割り当てます。
const COLORS := [
	Color("#ff5d73"), Color("#4cc9f0"), Color("#ffd166"), Color("#06d6a0"),
	Color("#b388ff"), Color("#ff9f43"), Color("#f78fb3"), Color("#a0e426"),
]

## 参加しているプレイヤーの一覧。
## 形: { ピアID(数字): {"name": 名前, "color": 色} }
var players := {}
## 自分の名前(タイトル画面で入力)
var my_name := "プレイヤー"
## オンライン中なら true、ひとりで遊んでいるなら false
var online := false

## CPUの強さ。0 = よわい、1 = ふつう、2 = つよい(CPUを動かすホストの設定が使われます)
var cpu_level := 1
const CPU_LEVEL_NAMES := ["よわい", "ふつう", "つよい"]
## CPUの強さが変わったときの合図(ボタンの表示を合わせるため)
signal cpu_level_changed


## CPUの強さを変える
func set_cpu_level(level: int) -> void:
	cpu_level = clampi(level, 0, 2)
	cpu_level_changed.emit()

## 日本語を表示するためのフォント。
## ブラウザ版(スマホ)にはパソコンのフォントがないので、フォントファイルをゲームに入れています。
## M PLUS Rounded 1c(SIL Open Font License。fonts/OFL.txt を見てください)
var font: Font = preload("res://fonts/MPLUSRounded1c-Bold.ttf")


## ブラウザ版(スマホなど)で動いているなら true
func is_web() -> bool:
	return OS.has_feature("web")


## CPUの強さに合わせた値を返す。例: cpu_value(0.5, 0.8, 1.0)
func cpu_value(weak: float, normal: float, strong: float) -> float:
	return [weak, normal, strong][clampi(cpu_level, 0, 2)]


func _ready() -> void:
	# すべての文字(ボタン・ラベル)の標準フォントにする
	ThemeDB.fallback_font = font
	ThemeDB.fallback_font_size = 22

	# ルームの係(scripts/room.gd)
	room = RoomScript.new()
	add_child(room)
	room.room_ready.connect(_on_room_ready)
	room.failed.connect(_on_room_failed)

	# 通信のできごとが起きたときに呼ばれる関数をつないでおく
	multiplayer.peer_connected.connect(_on_peer_connected)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	multiplayer.connected_to_server.connect(_on_connected_to_host)
	multiplayer.connection_failed.connect(_on_connection_failed)
	multiplayer.server_disconnected.connect(_on_host_disconnected)


# ───────── 遊び方ごとの開始処理 ─────────

## ひとりで遊ぶ(通信しない)
func start_solo() -> void:
	multiplayer.multiplayer_peer = OfflineMultiplayerPeer.new()
	online = false
	players = {1: {"name": my_name, "color": COLORS[0]}}
	players_changed.emit()


## ルームを作る(ホストになる)。パスワードができると room_ready の合図が来ます。
func host_room() -> void:
	leave()
	multiplayer.multiplayer_peer = room.start_host()
	online = true
	room_code = room.code
	players = {1: {"name": my_name, "color": COLORS[0]}}


## パスワードを入れてルームに入る。つながると connected_to_server が来ます。
func join_room(code: String) -> void:
	leave()
	multiplayer.multiplayer_peer = room.start_guest(code)
	online = true
	room_code = room.code
	players = {}


## 通信をやめてタイトルに戻るときに使う
func leave() -> void:
	room.stop()
	if multiplayer.multiplayer_peer:
		multiplayer.multiplayer_peer.close()
	multiplayer.multiplayer_peer = OfflineMultiplayerPeer.new()
	online = false
	room_code = ""
	players = {}


func _on_room_ready(code: String) -> void:
	room_ready.emit(code)
	players_changed.emit()


func _on_room_failed(message: String) -> void:
	leave()
	connection_problem.emit(message)


# ───────── 通信のできごと ─────────

## 部屋に入れたとき(クライアント側で呼ばれる)→ ホストに名前を送って登録してもらう
func _on_connected_to_host() -> void:
	_register.rpc_id(1, my_name)


## クライアントから名前が届いたとき(ホスト側で実行される)
@rpc("any_peer", "call_remote", "reliable")
func _register(player_name: String) -> void:
	if not multiplayer.is_server():
		return
	var id := multiplayer.get_remote_sender_id()
	players[id] = {"name": player_name.strip_edges().substr(0, 12), "color": _unused_color()}
	_send_players.rpc(players)          # 全員に新しい一覧を配る
	players_changed.emit()
	# 今いる画面(広場やゲーム)を新しい人にも読み込んでもらう
	get_node("/root/Main").send_current_scene_to(id)


## ホストから配られたプレイヤー一覧を受け取る(クライアント側)
@rpc("authority", "call_remote", "reliable")
func _send_players(data: Dictionary) -> void:
	players = data
	players_changed.emit()


func _on_peer_connected(_id: int) -> void:
	pass  # 名前が届くまで一覧には入れない(_register で入れる)


## だれかが抜けたとき
func _on_peer_disconnected(id: int) -> void:
	if multiplayer.is_server() and players.has(id):
		players.erase(id)
		_send_players.rpc(players)
		players_changed.emit()


func _on_connection_failed() -> void:
	leave()
	connection_problem.emit("ルームに入れませんでした。パスワードを確かめてください。")


func _on_host_disconnected() -> void:
	leave()
	connection_problem.emit("ホストとの接続が切れました。")


## まだ誰も使っていない色を返す
func _unused_color() -> Color:
	var used := []
	for p in players.values():
		used.append(p["color"])
	for c in COLORS:
		if not used.has(c):
			return c
	return Color.from_hsv(randf(), 0.6, 1.0)
