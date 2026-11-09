extends Node
## ─────────────────────────────────────────────
## Main(ゲーム全体の司令塔)
## ─────────────────────────────────────────────
## ゲームを起動すると最初に動くスクリプトです(scenes/main.tscn についています)。
##
## やっていること:
##   1. キーボード・コントローラーのボタンを登録する
##   2. タイトル画面を出す
##        「プレイ」   → ゲーム一覧 → 選んだゲームをひとり(+CPU)で遊ぶ
##        「オンライン」→ 部屋を作る / 部屋に入る → みんなで広場に集まって遊ぶ
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
	"spin_bar": preload("res://scripts/games/spin_bar.gd"),
}

## 広場のポータルに出すゲームの説明。bots = 人数が足りないときCPUを入れるか
const GAMES := [
	{"id": "coin_rush", "title": "コインラッシュ", "mode": "対戦", "color": Color("#ffd166"), "bots": true,
		"text": "60秒でコインを一番多く集めた人の勝ち。\n金の大コインは5枚ぶん!"},
	{"id": "bump_ring", "title": "ぶつかりリング", "mode": "対戦", "color": Color("#ff5d73"), "bots": true,
		"text": "ダッシュで相手をリングから押し出そう。\nリングはだんだん小さくなる!"},
	{"id": "panel_drop", "title": "ぬけおちパネル", "mode": "対戦", "color": Color("#4cc9f0"), "bots": true,
		"text": "乗ったパネルは落ちていく。\n最後まで残った人の勝ち!"},
	{"id": "spin_bar", "title": "ぐるぐるバー", "mode": "対戦", "color": Color("#b388ff"), "bots": true,
		"text": "回ってくるバーをジャンプでとびこえよう。\n当たると飛ばされる!"},
]

## CPUを入れて、最低この人数にする
const MIN_PLAYERS_WITH_BOTS := 4

var current_scene := ""        # 今の画面の名前
var current_participants := [] # 今の画面の参加者
var _title_ui: Control
var _message_label: Label
var _pages := {}               # タイトル画面のページ: "top"(はじめ) / "play"(ゲーム一覧) / "online"(接続)
var _name_edit: LineEdit
var pause_menu: CanvasLayer    # ポーズメニュー(scripts/pause_menu.gd)
var touch: Control             # スマホ用の画面ボタン(scripts/touch_controls.gd)


func _ready() -> void:
	randomize()
	_setup_input()
	Net.connection_problem.connect(_on_connection_problem)
	Net.players_changed.connect(_on_players_changed)
	_show_title()

	# ポーズメニュー
	pause_menu = preload("res://scripts/pause_menu.gd").new()
	pause_menu.main = self
	add_child(pause_menu)
	# スマホ用の画面ボタン(タッチ画面のときだけ表示される)
	var touch_layer := CanvasLayer.new()
	touch_layer.layer = 15
	add_child(touch_layer)
	touch = preload("res://scripts/touch_controls.gd").new()
	touch.main = self
	touch_layer.add_child(touch)

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
	_add_action("pause", [KEY_ESCAPE, KEY_P], [JOY_BUTTON_START], [])


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
	get_tree().paused = false   # 画面を切りかえるときは、ポーズを必ず解除する
	if pause_menu:
		pause_menu.visible = false
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


## ゲームが終わったあとに戻る場所
##   オンライン → みんなで広場へ(ホストだけが決める)
##   ひとりで遊んでいる → タイトルのゲーム一覧へ
func back_to_hub() -> void:
	if not Net.online:
		_back_to_title_page("play")
		return
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
	shade.color = Color(0.05, 0.05, 0.15, 0.5)
	shade.set_anchors_preset(Control.PRESET_FULL_RECT)
	_title_ui.add_child(shade)

	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	_title_ui.add_child(center)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 14)
	center.add_child(box)

	# タイトルの文字を1文字ずつちがう色にする
	var logo := RichTextLabel.new()
	logo.bbcode_enabled = true
	logo.fit_content = true
	logo.scroll_active = false
	logo.custom_minimum_size = Vector2(760, 0)
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

	# ページを3つ作って、同じ場所に重ねておく(見せるのは1つだけ)
	_pages["top"] = _build_top_page()
	_pages["play"] = _build_play_page()
	_pages["online"] = _build_online_page()
	for page in _pages.values():
		box.add_child(page)

	_message_label = Label.new()
	_message_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_message_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_message_label.custom_minimum_size = Vector2(600, 0)
	_message_label.add_theme_color_override("font_color", Color("#ffd166"))
	box.add_child(_message_label)

	var keys := Label.new()
	keys.text = "移動 WASD/矢印  ジャンプ Space  ダッシュ Shift  カメラ Q/E  ポーズ Esc/P  (コントローラーも使えます)"
	if touch_screen():
		keys.text = "画面の左側をさわって移動 ・ 右側をなぞってカメラ ・ 右下のボタンでジャンプ/ダッシュ"
	keys.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	keys.add_theme_font_size_override("font_size", 16)
	keys.add_theme_color_override("font_color", Color(1, 1, 1, 0.75))
	box.add_child(keys)

	_show_page("top")


## タイトルのページを切りかえる
func _show_page(page_name: String) -> void:
	for key in _pages:
		_pages[key].visible = key == page_name
	_set_message("")
	# 最初のボタンにフォーカスを当てて、キーボードやコントローラーでも選べるようにする
	var first := _first_button(_pages[page_name])
	if first:
		first.grab_focus.call_deferred()


func _first_button(node: Node) -> Button:
	for child in node.get_children():
		if child is Button:
			return child
		var found := _first_button(child)
		if found:
			return found
	return null


## はじめのページ: 名前・プレイ・オンライン
func _build_top_page() -> Control:
	var page := VBoxContainer.new()
	page.add_theme_constant_override("separation", 14)
	page.custom_minimum_size = Vector2(420, 0)
	page.size_flags_horizontal = Control.SIZE_SHRINK_CENTER

	var sub := Label.new()
	sub.text = "みんなで遊べる3Dミニゲーム集"
	sub.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	page.add_child(sub)

	_name_edit = LineEdit.new()
	_name_edit.placeholder_text = "あなたの名前"
	_name_edit.text = Net.my_name
	_name_edit.max_length = 12
	_name_edit.alignment = HORIZONTAL_ALIGNMENT_CENTER
	page.add_child(_name_edit)

	var play := _big_button("プレイ", Color("#06d6a0"))
	play.custom_minimum_size.y = 68
	play.add_theme_font_size_override("font_size", 32)
	play.pressed.connect(func(): _show_page("play"))
	page.add_child(play)

	var online := _big_button("オンライン", Color("#4cc9f0"))
	online.custom_minimum_size.y = 68
	online.add_theme_font_size_override("font_size", 32)
	online.pressed.connect(func():
		if Net.is_web():
			# ブラウザ版では、パソコンどうしをつなぐ通信(ENet)が使えない
			_set_message("ブラウザ版ではオンライン対戦はできません。\nみんなで遊ぶときはパソコン版(my web からダウンロード)を使ってね。")
		else:
			_show_page("online"))
	page.add_child(online)
	return page


## ゲーム一覧のページ: ゲームを選ぶと、ひとり(+CPU)ですぐ始まる
func _build_play_page() -> Control:
	var page := VBoxContainer.new()
	page.add_theme_constant_override("separation", 12)

	var head := Label.new()
	head.text = "ゲームをえらぼう"
	head.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	head.add_theme_font_size_override("font_size", 30)
	page.add_child(head)

	# ゲームのカードを2列にならべる
	var grid := GridContainer.new()
	grid.columns = 2
	grid.add_theme_constant_override("h_separation", 14)
	grid.add_theme_constant_override("v_separation", 14)
	page.add_child(grid)
	for g in GAMES:
		grid.add_child(_game_card(g))

	# CPUのつよさを選ぶ列
	var level_row := cpu_level_row()
	level_row.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	page.add_child(level_row)

	var back := _big_button("もどる", Color("#c7c9d9"))
	back.custom_minimum_size = Vector2(220, 48)
	back.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	back.pressed.connect(func(): _show_page("top"))
	page.add_child(back)
	return page


## ゲーム1つぶんのカード(押すとそのゲームが始まる大きなボタン)
func _game_card(g: Dictionary) -> Button:
	var color: Color = g["color"]
	var b := _big_button("", color)
	b.custom_minimum_size = Vector2(360, 120)
	b.focus_mode = Control.FOCUS_ALL
	# ボタンの中に文字を2段で並べる(タイトルと説明)
	var inner := VBoxContainer.new()
	inner.set_anchors_preset(Control.PRESET_FULL_RECT)
	inner.offset_left = 18
	inner.offset_right = -18
	inner.offset_top = 12
	inner.mouse_filter = Control.MOUSE_FILTER_IGNORE
	b.add_child(inner)
	var title := Label.new()
	title.text = "%s  [%s]" % [g["title"], g["mode"]]
	title.add_theme_font_size_override("font_size", 26)
	title.add_theme_color_override("font_color", Color("#1b1f4a"))
	title.mouse_filter = Control.MOUSE_FILTER_IGNORE
	inner.add_child(title)
	var text := Label.new()
	text.text = g["text"]
	text.add_theme_font_size_override("font_size", 16)
	text.add_theme_color_override("font_color", Color("#1b1f4a"))
	text.mouse_filter = Control.MOUSE_FILTER_IGNORE
	inner.add_child(text)
	b.pressed.connect(func(): _start_solo_game(g["id"]))
	return b


## 「CPUのつよさ: よわい / ふつう / つよい」の列を作る(タイトルと広場で使う)
func cpu_level_row() -> HBoxContainer:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	var label := Label.new()
	label.text = "CPUのつよさ"
	label.add_theme_font_size_override("font_size", 20)
	row.add_child(label)
	var level_colors := [Color("#8fd694"), Color("#ffd166"), Color("#ff7b7b")]
	var buttons := []
	for i in Net.CPU_LEVEL_NAMES.size():
		var b := _big_button(Net.CPU_LEVEL_NAMES[i], level_colors[i])
		b.custom_minimum_size = Vector2(110, 44)
		b.add_theme_font_size_override("font_size", 20)
		b.toggle_mode = true
		b.button_pressed = Net.cpu_level == i
		# 選ばれているボタンは白いふちで目立たせる
		var on: StyleBoxFlat = b.get_theme_stylebox("focus").duplicate()
		b.add_theme_stylebox_override("pressed", on)
		buttons.append(b)
		row.add_child(b)
	for i in buttons.size():
		buttons[i].pressed.connect(func(): Net.set_cpu_level(i))
	# 1つだけ押されている状態にする(タイトルと広場、両方の列を合わせる)
	var refresh := func():
		for j in buttons.size():
			if is_instance_valid(buttons[j]):
				buttons[j].set_pressed_no_signal(Net.cpu_level == j)
	Net.cpu_level_changed.connect(refresh)
	row.tree_exiting.connect(func():
		if Net.cpu_level_changed.is_connected(refresh):
			Net.cpu_level_changed.disconnect(refresh))
	return row


## タッチ画面(スマホ・タブレット)か
func touch_screen() -> bool:
	return DisplayServer.is_touchscreen_available() or OS.get_cmdline_user_args().has("--touch")


## ひとりでゲームを始める(足りない人数はCPU)
func _start_solo_game(game_id: String) -> void:
	Net.my_name = _name_from(_name_edit)
	Net.start_solo()
	start_game(game_id)


## オンラインのページ: 部屋を作る / IPアドレスを入れて部屋に入る
func _build_online_page() -> Control:
	var page := VBoxContainer.new()
	page.add_theme_constant_override("separation", 14)
	page.custom_minimum_size = Vector2(520, 0)
	page.size_flags_horizontal = Control.SIZE_SHRINK_CENTER

	var head := Label.new()
	head.text = "オンラインで遊ぶ"
	head.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	head.add_theme_font_size_override("font_size", 30)
	page.add_child(head)

	var how := Label.new()
	how.text = "1人が「部屋を作る」を押して、広場に出るIPアドレスをみんなに教えます。\nほかの人はそのIPアドレスを入れて「部屋に入る」を押します。"
	how.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	how.add_theme_font_size_override("font_size", 16)
	how.add_theme_color_override("font_color", Color(1, 1, 1, 0.8))
	page.add_child(how)

	var host := _big_button("部屋を作る(ホスト)", Color("#ffd166"))
	host.pressed.connect(func():
		Net.my_name = _name_from(_name_edit)
		_on_host_pressed(Net.DEFAULT_PORT))
	page.add_child(host)

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	var ip_edit := LineEdit.new()
	ip_edit.placeholder_text = "ホストのIPアドレス(例 192.168.0.5)"
	ip_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(ip_edit)
	var join := _big_button("部屋に入る", Color("#4cc9f0"))
	join.pressed.connect(func():
		Net.my_name = _name_from(_name_edit)
		var address := ip_edit.text.strip_edges()
		if address == "":
			address = "127.0.0.1"
		if Net.join_room(address, Net.DEFAULT_PORT) != OK:
			_set_message("接続を始められませんでした。")
		else:
			_set_message("%s に接続しています…" % address))
	row.add_child(join)
	page.add_child(row)

	var back := _big_button("もどる", Color("#c7c9d9"))
	back.custom_minimum_size = Vector2(220, 48)
	back.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	back.pressed.connect(func():
		if Net.online:
			Net.leave()   # 接続中ならやめる
		_show_page("top"))
	page.add_child(back)
	return page


func _on_host_pressed(port: int) -> void:
	var err := Net.host_room(port)
	if err != OK:
		_set_message("部屋を作れませんでした(ポート %d が使用中かもしれません)。" % port)
		return
	load_scene("hub", hub_participants())


## タイトル画面に戻る(広場の「タイトルに戻る」ボタンなど)
func back_to_title(message := "") -> void:
	_back_to_title_page("top")
	_set_message(message)


## タイトルの、指定したページに戻る
func _back_to_title_page(page_name: String) -> void:
	Net.leave()
	load_scene("hub", [])
	current_scene = ""
	_title_ui.visible = true
	_show_page(page_name)


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
			# 選ばれているボタン(キーボード・コントローラー用)は白いふちで目立たせる
			s.bg_color = color
			s.border_color = Color.WHITE
			s.set_border_width_all(4)
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
	# タイトル画面の3つのページを順番に表示する
	for page in ["top", "play", "online"]:
		_show_page(page)
		await get_tree().create_timer(3.0 if page == "top" else 1.5).timeout
		_autotest_shot("title_" + page)
	_show_page("top")
	Net.start_solo()
	for id in ["hub", "coin_rush", "bump_ring", "panel_drop", "spin_bar"]:
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
		_autotest_shot(id)
	get_tree().quit()


## 画面があるときは、スクリーンショットを保存する(自動テスト用)
func _autotest_shot(shot_name: String) -> void:
	if DisplayServer.get_name() == "headless":
		return
	var shot := "user://autotest_%s.png" % shot_name
	get_viewport().get_texture().get_image().save_png(shot)
	print("SHOT ", ProjectSettings.globalize_path(shot))


## 2台(ホストとゲスト)で同時に起動して、通信できるか確かめる
func _autotest_online(is_host: bool) -> void:
	var who := "HOST" if is_host else "GUEST"
	await get_tree().create_timer(4.0).timeout
	for id in ["coin_rush", "panel_drop", "bump_ring", "spin_bar", "hub"]:
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
