extends Node
## ─────────────────────────────────────────────
## Main(ゲーム全体の司令塔)
## ─────────────────────────────────────────────
## ゲームを起動すると最初に動くスクリプトです(scenes/main.tscn についています)。
##
## やっていること:
##   1. キーボード・コントローラーのボタンを登録する
##   2. タイトル画面(名前入力・ひとりで遊ぶ・部屋を作る・部屋に入る)を出す
##   3. 「広場」や「ミニゲーム」を切りかえる
##
## 画面の切りかえは「Game」という名前のノードを入れかえて行います。
## 全員のパソコンで同じ名前・同じ場所にノードがあるので、RPC が正しく届きます。

const Build = preload("res://scripts/build.gd")

## 遊べる画面の一覧。名前 → スクリプト
const SCENES := {
	"hub": preload("res://scripts/hub.gd"),
	"coin_rush": preload("res://scripts/games/coin_rush.gd"),
	"bump_ring": preload("res://scripts/games/bump_ring.gd"),
	"panel_drop": preload("res://scripts/games/panel_drop.gd"),
	"crystal_island": preload("res://scripts/games/crystal_island.gd"),
}

## 広場のポータルに出すゲームの説明。bots = 人数が足りないときCPUを入れるか
const GAMES := [
	{"id": "coin_rush", "title": "コインラッシュ", "mode": "対戦", "color": Color("#ffd166"), "bots": true,
		"text": "60秒でコインを一番多く集めた人の勝ち。\n金の大コインは5枚ぶん!"},
	{"id": "bump_ring", "title": "ぶつかりリング", "mode": "対戦", "color": Color("#ff5d73"), "bots": true,
		"text": "ダッシュで相手をリングから押し出そう。\nリングはだんだん小さくなる!"},
	{"id": "panel_drop", "title": "ぬけおちパネル", "mode": "対戦", "color": Color("#4cc9f0"), "bots": true,
		"text": "乗ったパネルは落ちていく。\n最後まで残った人の勝ち!"},
	{"id": "crystal_island", "title": "浮島クリスタル", "mode": "協力", "color": Color("#06d6a0"), "bots": false,
		"text": "みんなで協力してクリスタル集め。\nトゲ玉に当たると1個なくなる!"},
]

## CPUを入れて、最低この人数にする
const MIN_PLAYERS_WITH_BOTS := 4

var current_scene := ""        # 今の画面の名前
var current_participants := [] # 今の画面の参加者
var _title_ui: Control
var _message_label: Label


func _ready() -> void:
	randomize()
	_setup_input()
	Net.connection_problem.connect(_on_connection_problem)
	Net.players_changed.connect(_on_players_changed)
	_show_title()

	# テスト用: コマンドラインで起動したときの自動テスト(ふつうに遊ぶときは使わない)
	var args := OS.get_cmdline_user_args()
	if args.has("--autotest"):
		_autotest()
	elif args.has("--autohost"):
		Net.my_name = "ホスト"
		_on_host_pressed(Net.DEFAULT_PORT)
		_autotest_online(true)
	elif args.has("--autojoin"):
		Net.my_name = "ゲスト"
		Net.join_room("127.0.0.1", Net.DEFAULT_PORT)
		_autotest_online(false)


# ─────────── 操作の登録 ───────────

## 「move_left」などの操作の名前に、キーやボタンをむすびつける
func _setup_input() -> void:
	_add_action("move_left", [KEY_A, KEY_LEFT], [], [JOY_AXIS_LEFT_X, -1.0])
	_add_action("move_right", [KEY_D, KEY_RIGHT], [], [JOY_AXIS_LEFT_X, 1.0])
	_add_action("move_forward", [KEY_W, KEY_UP], [], [JOY_AXIS_LEFT_Y, -1.0])
	_add_action("move_back", [KEY_S, KEY_DOWN], [], [JOY_AXIS_LEFT_Y, 1.0])
	_add_action("jump", [KEY_SPACE], [JOY_BUTTON_A], [])
	_add_action("dash", [KEY_SHIFT, KEY_K], [JOY_BUTTON_X], [])
	_add_action("cam_left", [KEY_Q], [JOY_BUTTON_LEFT_SHOULDER], [])
	_add_action("cam_right", [KEY_E], [JOY_BUTTON_RIGHT_SHOULDER], [])


func _add_action(action: String, keys: Array, buttons: Array, axis: Array) -> void:
	if InputMap.has_action(action):
		return
	InputMap.add_action(action, 0.25)
	for k in keys:
		var e := InputEventKey.new()
		e.physical_keycode = k
		InputMap.action_add_event(action, e)
	for b in buttons:
		var e := InputEventJoypadButton.new()
		e.button_index = b
		InputMap.action_add_event(action, e)
	if axis.size() == 2:
		var e := InputEventJoypadMotion.new()
		e.axis = axis[0]
		e.axis_value = axis[1]
		InputMap.action_add_event(action, e)


# ─────────── 画面の切りかえ ───────────

## 画面を読み込む。ホストが .rpc() で呼ぶと、全員のパソコンで同じ画面になる
@rpc("authority", "call_local", "reliable")
func load_scene(scene_name: String, participants: Array) -> void:
	var old := get_node_or_null("Game")
	if old:
		remove_child(old)   # すぐに外して、新しい「Game」と名前がぶつからないようにする
		old.queue_free()
	current_scene = scene_name
	current_participants = participants
	var game: Node3D = SCENES[scene_name].new()
	game.name = "Game"
	game.participants = participants
	add_child(game)
	# 参加者がいる画面に入ったら、タイトル画面を隠す(参加者0人 = タイトルの背景)
	if _title_ui and participants.size() > 0:
		_title_ui.visible = false


## 途中から入ってきた人に、今の画面を送る(ホストだけが呼ぶ)
func send_current_scene_to(peer_id: int) -> void:
	if current_scene == "":
		return
	load_scene.rpc_id(peer_id, current_scene, current_participants)


## 広場に戻る(ホストだけ)
func back_to_hub() -> void:
	if multiplayer.is_server():
		load_scene.rpc("hub", hub_participants())


## 広場の参加者 = 今いるプレイヤー全員(CPUなし)
func hub_participants() -> Array:
	var list := []
	var ids := Net.players.keys()
	ids.sort()
	for id in ids:
		var p: Dictionary = Net.players[id]
		list.append({"key": str(id), "auth": id, "name": p["name"], "color": p["color"], "bot": false})
	return list


## ミニゲームを始める(ホストだけ)。人数が足りなければCPUを足す
func start_game(game_id: String) -> void:
	if not multiplayer.is_server():
		return
	var list := hub_participants()
	var info: Dictionary = {}
	for g in GAMES:
		if g["id"] == game_id:
			info = g
	if info.get("bots", false):
		var n := 1
		var cpu_colors := [Color("#9aa0b5"), Color("#c9a27e"), Color("#8fb996")]
		while list.size() < MIN_PLAYERS_WITH_BOTS:
			list.append({"key": "cpu%d" % n, "auth": 1, "name": "CPU%d" % n,
				"color": cpu_colors[(n - 1) % cpu_colors.size()], "bot": true})
			n += 1
	load_scene.rpc(game_id, list)


## プレイヤーが増えた・減ったとき(広場ならキャラを足したり消したりする)
func _on_players_changed() -> void:
	var game := get_node_or_null("Game")
	if game and game.has_method("sync_players_with_net"):
		game.sync_players_with_net()
	# クライアントで、まだ画面が無いとき(入った直後)はタイトルを隠して待つ
	if Net.online and not multiplayer.is_server() and _title_ui:
		_title_ui.visible = current_scene == ""
		if current_scene == "":
			_set_message("ホストの画面を読み込んでいます…")


# ─────────── タイトル画面 ───────────

func _show_title() -> void:
	# 後ろには広場をCPUなしで表示して、カメラをぐるぐる回す
	load_scene("hub", [])
	current_scene = ""

	var layer := CanvasLayer.new()
	layer.layer = 10
	add_child(layer)
	_title_ui = Control.new()
	_title_ui.set_anchors_preset(Control.PRESET_FULL_RECT)
	layer.add_child(_title_ui)

	var shade := ColorRect.new()
	shade.color = Color(0.05, 0.05, 0.15, 0.45)
	shade.set_anchors_preset(Control.PRESET_FULL_RECT)
	_title_ui.add_child(shade)

	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	_title_ui.add_child(center)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 14)
	box.custom_minimum_size = Vector2(460, 0)
	center.add_child(box)

	# タイトルの文字を1文字ずつちがう色にする
	var logo := RichTextLabel.new()
	logo.bbcode_enabled = true
	logo.fit_content = true
	logo.scroll_active = false
	logo.add_theme_font_size_override("normal_font_size", 92)
	logo.add_theme_constant_override("outline_size", 18)
	logo.add_theme_color_override("font_outline_color", Color("#1b1f4a"))
	var letters := "Freedom Land"
	var bb := "[center]"
	for i in letters.length():
		var c: Color = Net.COLORS[i % Net.COLORS.size()]
		bb += "[color=#%s]%s[/color]" % [c.to_html(false), letters[i]]
	logo.text = bb + "[/center]"
	box.add_child(logo)

	var sub := Label.new()
	sub.text = "みんなで遊べる3Dミニゲーム集"
	sub.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(sub)

	var name_edit := LineEdit.new()
	name_edit.name = "NameEdit"
	name_edit.placeholder_text = "あなたの名前"
	name_edit.text = Net.my_name
	name_edit.max_length = 12
	box.add_child(name_edit)

	var solo := _big_button("ひとりで遊ぶ", Color("#06d6a0"))
	solo.pressed.connect(func():
		Net.my_name = _name_from(name_edit)
		Net.start_solo()
		load_scene("hub", hub_participants()))
	box.add_child(solo)

	var host := _big_button("部屋を作る(ホスト)", Color("#ffd166"))
	host.pressed.connect(func():
		Net.my_name = _name_from(name_edit)
		_on_host_pressed(Net.DEFAULT_PORT))
	box.add_child(host)

	var row := HBoxContainer.new()
	var ip_edit := LineEdit.new()
	ip_edit.placeholder_text = "ホストのIPアドレス(例 192.168.0.5)"
	ip_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(ip_edit)
	var join := _big_button("部屋に入る", Color("#4cc9f0"))
	join.pressed.connect(func():
		Net.my_name = _name_from(name_edit)
		var address := ip_edit.text.strip_edges()
		if address == "":
			address = "127.0.0.1"
		if Net.join_room(address, Net.DEFAULT_PORT) != OK:
			_set_message("接続を始められませんでした。")
		else:
			_set_message("%s に接続しています…" % address))
	row.add_child(join)
	box.add_child(row)

	_message_label = Label.new()
	_message_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_message_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_message_label.add_theme_color_override("font_color", Color("#ffd166"))
	box.add_child(_message_label)

	var keys := Label.new()
	keys.text = "移動 WASD/矢印  ジャンプ Space  ダッシュ Shift  カメラ Q/E  (コントローラーも使えます)"
	keys.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	keys.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	keys.add_theme_font_size_override("font_size", 16)
	keys.add_theme_color_override("font_color", Color(1, 1, 1, 0.75))
	box.add_child(keys)


func _on_host_pressed(port: int) -> void:
	var err := Net.host_room(port)
	if err != OK:
		_set_message("部屋を作れませんでした(ポート %d が使用中かもしれません)。" % port)
		return
	load_scene("hub", hub_participants())


## タイトル画面に戻る
func back_to_title(message := "") -> void:
	Net.leave()
	load_scene("hub", [])
	current_scene = ""
	_title_ui.visible = true
	_set_message(message)


func _on_connection_problem(message: String) -> void:
	back_to_title(message)


func _set_message(text: String) -> void:
	if _message_label:
		_message_label.text = text


func _name_from(edit: LineEdit) -> String:
	var n := edit.text.strip_edges()
	return n if n != "" else "プレイヤー"


## 色つきの大きなボタンを作る
func _big_button(text: String, color: Color) -> Button:
	var b := Button.new()
	b.text = text
	b.custom_minimum_size = Vector2(0, 54)
	b.add_theme_font_size_override("font_size", 24)
	for state in ["normal", "hover", "pressed", "focus"]:
		var s := StyleBoxFlat.new()
		s.bg_color = color.darkened(0.15) if state == "normal" else color
		if state == "pressed":
			s.bg_color = color.darkened(0.3)
		if state == "focus":
			s.bg_color = Color(0, 0, 0, 0)
			s.border_color = Color.WHITE
			s.set_border_width_all(3)
		s.set_corner_radius_all(14)
		s.content_margin_left = 18
		s.content_margin_right = 18
		b.add_theme_stylebox_override(state, s)
	b.add_theme_color_override("font_color", Color("#1b1f4a"))
	b.add_theme_color_override("font_hover_color", Color("#1b1f4a"))
	b.add_theme_color_override("font_pressed_color", Color("#1b1f4a"))
	b.add_theme_color_override("font_focus_color", Color("#1b1f4a"))
	return b


# ─────────── 自動テスト(開発用) ───────────

## すべての画面を順番に開いて、エラーが出ないか確かめる
func _autotest() -> void:
	Net.my_name = "テスト"
	Net.start_solo()
	for id in ["hub", "coin_rush", "bump_ring", "panel_drop", "crystal_island"]:
		if id == "hub":
			load_scene("hub", hub_participants())
		else:
			start_game(id)
		for s in 6:
			await get_tree().create_timer(1.0).timeout
			var me = get_node("Game").players.get(str(multiplayer.get_unique_id()))
			if me:
				print("  ", id, " t=", s, " pos=", me.global_position.snapped(Vector3.ONE * 0.1), " input=", Input.get_vector("move_left", "move_right", "move_forward", "move_back"))
		print("AUTOTEST OK: ", id, "  players=", get_node("Game").players.size())
		# 画面があるときは、スクリーンショットを保存する
		if DisplayServer.get_name() != "headless":
			var shot := "user://autotest_%s.png" % id
			get_viewport().get_texture().get_image().save_png(shot)
			print("SHOT ", ProjectSettings.globalize_path(shot))
	get_tree().quit()


## 2台(ホストとゲスト)で同時に起動して、通信できるか確かめる
func _autotest_online(is_host: bool) -> void:
	var who := "HOST" if is_host else "GUEST"
	await get_tree().create_timer(4.0).timeout
	for id in ["coin_rush", "panel_drop", "bump_ring", "crystal_island", "hub"]:
		if is_host:
			if id == "hub":
				back_to_hub()
			else:
				start_game(id)
		await get_tree().create_timer(9.0).timeout
		var g := get_node_or_null("Game")
		var keys: Array = g.players.keys() if g else []
		print("NETTEST %s: scene=%s players=%s scores=%s net=%s" % [who, current_scene, keys, g.scores if g else {}, Net.players.keys()])
	get_tree().quit()
