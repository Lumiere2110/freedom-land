extends CanvasLayer
## ─────────────────────────────────────────────
## PauseMenu(ポーズメニュー)
## ─────────────────────────────────────────────
## ゲーム中に Esc / P キー、コントローラーのスタートボタン、
## スマホなら画面上の「II」ボタンで開きます。
##
##   ・ひとりで遊んでいるとき → ゲーム全体を止める(get_tree().paused = true)
##   ・オンラインのとき → みんなのゲームは止められないので、メニューだけ出す
##
## process_mode = ALWAYS にしているので、ゲームが止まっていてもこのメニューは動きます。

var main: Node
var _box: VBoxContainer
var _note: Label


func _ready() -> void:
	layer = 20
	process_mode = Node.PROCESS_MODE_ALWAYS
	visible = false

	# 後ろを暗くする幕
	var shade := ColorRect.new()
	shade.color = Color(0.03, 0.03, 0.1, 0.65)
	shade.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(shade)

	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(center)
	_box = VBoxContainer.new()
	_box.add_theme_constant_override("separation", 12)
	_box.custom_minimum_size = Vector2(380, 0)
	center.add_child(_box)


## 今ポーズできる状態か(ゲームか広場にいるとき)
func can_pause() -> bool:
	return main.current_scene != "" and not main._title_ui.visible


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("pause"):
		toggle()
		get_viewport().set_input_as_handled()


func toggle() -> void:
	if visible:
		close()
	elif can_pause():
		open()


## メニューを開く。そのときの状態に合わせてボタンを作り直す
func open() -> void:
	for c in _box.get_children():
		c.queue_free()

	var title := Label.new()
	title.text = "ポーズ"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 52)
	title.add_theme_color_override("font_outline_color", Color("#1b1f4a"))
	title.add_theme_constant_override("outline_size", 12)
	_box.add_child(title)

	_note = Label.new()
	_note.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_note.add_theme_font_size_override("font_size", 16)
	_note.add_theme_color_override("font_color", Color(1, 1, 1, 0.8))
	_box.add_child(_note)

	_add_button("つづける", Color("#06d6a0"), close)
	if Net.online:
		_note.text = "オンライン中は、ゲームは止まりません"
		_add_button("部屋から出る", Color("#ff5d73"), func():
			close()
			main.back_to_title())
	else:
		_note.text = "ゲームを止めています"
		get_tree().paused = true
		# 空島(広場)にいるときは、ゲーム用のボタンは出さない
		if main.current_scene != "hub":
			_add_button("はじめからやりなおす", Color("#ffd166"), func():
				var scene: String = main.current_scene
				close()
				main.start_game(scene))
			_add_button("空島にもどる", Color("#4cc9f0"), func():
				close()
				main.back_to_hub())
		_add_button("タイトルにもどる", Color("#c7c9d9"), func():
			close()
			main.back_to_title())
	visible = true
	# 最初のボタンを選んでおく(キーボードやコントローラーで操作できるように)
	await get_tree().process_frame
	for c in _box.get_children():
		if c is Button:
			c.grab_focus()
			break


func close() -> void:
	visible = false
	get_tree().paused = false


func _add_button(text: String, color: Color, action: Callable) -> void:
	var b: Button = main._big_button(text, color)
	b.pressed.connect(action)
	_box.add_child(b)
