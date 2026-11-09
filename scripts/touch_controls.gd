extends Control
## ─────────────────────────────────────────────
## TouchControls(スマホ用の画面ボタン)
## ─────────────────────────────────────────────
## タッチ画面のときだけ出てくる、画面の上のボタンです。
##   ・左下: 移動スティック(画面の左半分のどこを触っても、そこがスティックの中心になる)
##   ・右下: ジャンプ(大きいボタン)とダッシュ
##   ・右半分をなぞる: カメラを回す
##   ・上: ポーズ「II」
##
## しくみ:
##   画面のボタンを押すと Input.action_press("jump") のように、
##   キーボードのキーを押したのと同じ合図を出しています。
##   なので、キャラクターのプログラム(player.gd)はそのままで動きます。

var main: Node
var enabled := false          # タッチ画面なら true

const STICK_RADIUS := 90.0    # スティックを倒しきるまでの距離(ピクセル)

var _stick_index := -1        # スティックを触っている指の番号(-1 = だれも触っていない)
var _stick_origin := Vector2.ZERO
var _stick_vec := Vector2.ZERO
var _cam_index := -1          # カメラを回している指の番号
var _cam_last_x := 0.0
var _button_fingers := {}     # 指の番号 → 押しているボタンの名前("jump" / "dash")


func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	process_mode = Node.PROCESS_MODE_ALWAYS
	enabled = DisplayServer.is_touchscreen_available() or OS.get_cmdline_user_args().has("--touch")


## ボタンを出してよいとき = タッチ画面で、ゲーム中で、ポーズしていないとき
func _active() -> bool:
	return enabled and main.current_scene != "" and not main._title_ui.visible \
		and not main.pause_menu.visible


## ボタンの場所(画面の大きさに合わせて計算)
func _jump_center() -> Vector2:
	return Vector2(size.x - 120, size.y - 130)

func _dash_center() -> Vector2:
	return Vector2(size.x - 275, size.y - 85)

func _pause_rect() -> Rect2:
	return Rect2(size.x / 2.0 - 190, 16, 64, 64)


func _input(event: InputEvent) -> void:
	if not _active():
		_release_all()
		return
	if event is InputEventScreenTouch:
		var p: Vector2 = event.position
		if event.pressed:
			if _pause_rect().grow(12).has_point(p):
				main.pause_menu.toggle()
				_release_all()
			elif p.distance_to(_jump_center()) < 85:
				_press_button(event.index, "jump")
			elif p.distance_to(_dash_center()) < 70:
				_press_button(event.index, "dash")
			elif p.x < size.x * 0.5 and p.y > size.y * 0.3 and _stick_index == -1:
				_stick_index = event.index
				_stick_origin = p
				_stick_vec = Vector2.ZERO
			elif p.x >= size.x * 0.5 and _cam_index == -1:
				_cam_index = event.index
				_cam_last_x = p.x
		else:
			_release_finger(event.index)
		queue_redraw()
	elif event is InputEventScreenDrag:
		if event.index == _stick_index:
			_stick_vec = ((event.position - _stick_origin) / STICK_RADIUS).limit_length(1.0)
			_apply_stick()
		elif event.index == _cam_index:
			var game := main.get_node_or_null("Game")
			if game:
				game.cam_yaw -= (event.position.x - _cam_last_x) * 0.006
			_cam_last_x = event.position.x
		queue_redraw()


## スティックの倒し具合を、移動キーの強さとして伝える
func _apply_stick() -> void:
	_set_strength("move_left", -_stick_vec.x)
	_set_strength("move_right", _stick_vec.x)
	_set_strength("move_forward", -_stick_vec.y)
	_set_strength("move_back", _stick_vec.y)


func _set_strength(action: String, value: float) -> void:
	if value > 0.15:
		Input.action_press(action, value)
	else:
		Input.action_release(action)


func _press_button(index: int, action: String) -> void:
	_button_fingers[index] = action
	Input.action_press(action)


func _release_finger(index: int) -> void:
	if index == _stick_index:
		_stick_index = -1
		_stick_vec = Vector2.ZERO
		_apply_stick()
	if index == _cam_index:
		_cam_index = -1
	if _button_fingers.has(index):
		Input.action_release(_button_fingers[index])
		_button_fingers.erase(index)


## 指をぜんぶ離したことにする(ポーズ・画面の切りかえのとき)
func _release_all() -> void:
	if _stick_index == -1 and _cam_index == -1 and _button_fingers.is_empty():
		return
	_stick_index = -1
	_cam_index = -1
	_stick_vec = Vector2.ZERO
	_apply_stick()
	for action in _button_fingers.values():
		Input.action_release(action)
	_button_fingers.clear()
	queue_redraw()


func _process(_delta: float) -> void:
	# 画面の大きさ(スマホの向きを変えると変わる)にいつも合わせる
	position = Vector2.ZERO
	size = get_viewport_rect().size
	queue_redraw()


## ボタンの絵をかく
func _draw() -> void:
	var font: Font = Net.font
	# ブラウザ版で縦向きのときは「横向きにしてね」を出す
	if Net.is_web() and size.y > size.x:
		draw_rect(Rect2(Vector2.ZERO, size), Color(0.06, 0.07, 0.18, 0.96))
		draw_string(font, Vector2(0, size.y / 2.0), "スマホを横向きにしてね", HORIZONTAL_ALIGNMENT_CENTER, size.x, 96)
		draw_string(font, Vector2(0, size.y / 2.0 + 110), "(画面の向きのロックを外してください)", HORIZONTAL_ALIGNMENT_CENTER, size.x, 48, Color(1, 1, 1, 0.7))
		return
	if not _active():
		return
	var white := Color(1, 1, 1, 0.85)

	# 移動スティック
	var base := _stick_origin if _stick_index != -1 else Vector2(150, size.y - 150)
	draw_circle(base, STICK_RADIUS, Color(1, 1, 1, 0.12))
	draw_arc(base, STICK_RADIUS, 0, TAU, 48, Color(1, 1, 1, 0.45), 3.0)
	draw_circle(base + _stick_vec * STICK_RADIUS, 38, Color(1, 1, 1, 0.55))

	# ジャンプ・ダッシュ
	_draw_round_button(_jump_center(), 72, "ジャンプ", Color("#06d6a0"), _button_fingers.values().has("jump"))
	_draw_round_button(_dash_center(), 56, "ダッシュ", Color("#ff9f43"), _button_fingers.values().has("dash"))

	# ポーズ
	var r := _pause_rect()
	draw_rect(r, Color(0, 0, 0, 0.35))
	draw_rect(Rect2(r.position + Vector2(20, 16), Vector2(8, 32)), white)
	draw_rect(Rect2(r.position + Vector2(36, 16), Vector2(8, 32)), white)


func _draw_round_button(center: Vector2, radius: float, text: String, color: Color, pressed: bool) -> void:
	var c := color
	c.a = 0.75 if pressed else 0.45
	draw_circle(center, radius, c)
	draw_arc(center, radius, 0, TAU, 48, Color(1, 1, 1, 0.7), 3.0)
	draw_string(Net.font, center + Vector2(-radius, 9), text, HORIZONTAL_ALIGNMENT_CENTER, radius * 2.0, 24)
