extends Node3D
## ─────────────────────────────────────────────
## BaseGame(すべてのゲームの「土台」)
## ─────────────────────────────────────────────
## 広場(hub.gd)と各ミニゲーム(games フォルダ)は、このスクリプトを
## 「extends」して作っています。extends は「この土台を受けついで作る」という意味です。
##
## 土台がやってくれること:
##   ・キャラを並べる ・カメラでキャラを追いかける
##   ・3,2,1 のカウントダウン ・残り時間 ・点数表 ・結果発表
##   ・CPU(bot)を動かすタイミングを作る
##
## 各ゲームが自分で書くこと(上書きする関数):
##   build_world()      … ステージを作る
##   spawn_point(i)     … i番目のキャラのスタート位置
##   on_start()         … スタートした瞬間の処理
##   game_process(dt)   … 毎フレームの処理
##   bot_think(bot, dt) … CPUの考え方
##   on_player_fell(p)  … 落ちたときの処理

const Build = preload("res://scripts/build.gd")
const PlayerScript = preload("res://scripts/player.gd")

# ───── 各ゲームが設定する値 ─────
var game_title := ""          # ゲームの名前(左上に出る)
var help_text := ""           # 画面の下に出る説明
var game_time := 60.0         # 制限時間(秒)
var is_hub := false           # 広場なら true(カウントダウンなどをしない)
var higher_is_better := true  # 点数が多いほうが上位なら true

# ───── 中で使う値 ─────
var participants: Array = []  # 参加者の情報(main.gd から渡される)
var players := {}             # キャラの名前 → キャラ(Player)
var scores := {}              # キャラの名前 → 点数
var local_key := ""           # 自分のキャラの名前
var state := "ready"          # "ready"=カウントダウン中 / "play"=プレイ中 / "result"=結果発表
var time_left := 0.0
var main: Node

# カメラ
var cam: Camera3D
var cam_yaw := 0.0
var cam_distance := 12.0
var cam_height := 9.0
var _orbit := 0.0

# 画面の文字(HUD = ヘッドアップディスプレイ)
var hud: Control
var timer_label: Label
var big_label: Label
var score_box: VBoxContainer
var help_label: Label


func _ready() -> void:
	main = get_node("/root/Main")
	local_key = str(multiplayer.get_unique_id())
	build_world()

	var root := Node3D.new()
	root.name = "Players"
	add_child(root)
	for i in participants.size():
		spawn_player(participants[i], i)

	cam = Camera3D.new()
	cam.fov = 60.0
	add_child(cam)
	cam.current = true
	_place_camera(1.0)

	_build_hud()
	refresh_scores()
	if is_hub:
		state = "play"
	else:
		_countdown()


## キャラを1人作って、ステージに置く
func spawn_player(info: Dictionary, index: int) -> Node:
	var p := PlayerScript.new()
	p.name = info["key"]
	p.key = info["key"]
	p.display_name = info["name"]
	p.color = info["color"]
	p.is_bot = info["bot"]
	p.game = self
	p.set_multiplayer_authority(info["auth"])  # このキャラを動かす担当のパソコン
	$Players.add_child(p)
	p.teleport(spawn_point(index))
	players[p.key] = p
	scores[p.key] = 0
	return p


## プレイヤー一覧が変わったとき: 抜けた人のキャラを消す(広場では入った人も足す)
func sync_players_with_net() -> void:
	for k in players.keys():
		var p: Node = players[k]
		if not p.is_bot and not Net.players.has(p.get_multiplayer_authority()):
			remove_player(k)


## キャラを消す(だれかが抜けたとき)
func remove_player(k: String) -> void:
	if players.has(k):
		players[k].queue_free()
		players.erase(k)
		scores.erase(k)
		refresh_scores()


# ─────────── 各ゲームで上書きする関数(ここでは何もしない) ───────────

func build_world() -> void:
	pass

func spawn_point(index: int) -> Vector3:
	return Vector3(cos(index * 1.7) * 3.0, 1.0, sin(index * 1.7) * 3.0)

func on_start() -> void:
	pass

func game_process(_delta: float) -> void:
	pass

func bot_think(_bot: Node, _delta: float) -> void:
	pass

## 落ちたとき: ふつうはスタート位置に戻す
func on_player_fell(p: Node) -> void:
	p.teleport(spawn_point(randi() % 4) + Vector3(0, 2, 0))

## ダッシュで相手にぶつかったとき(ぶつけた側のパソコンで呼ばれる)
func on_player_hit(_victim: Node, _attacker: Node) -> void:
	pass

## 結果発表のいちばん上に出す文
func result_header() -> String:
	return "結果発表"


# ─────────── 毎フレームの処理 ───────────

func _process(delta: float) -> void:
	# Q/E キーでカメラを回す
	if Input.is_action_pressed("cam_left"):
		cam_yaw += 2.2 * delta
	if Input.is_action_pressed("cam_right"):
		cam_yaw -= 2.2 * delta
	_place_camera(minf(1.0, 6.0 * delta))

	if state == "play" and not is_hub:
		time_left -= delta
		timer_label.text = str(maxi(0, ceili(time_left)))
		timer_label.modulate = Color("#ff6b6b") if time_left < 10.0 else Color.WHITE
		# 時間切れの判断はホストだけがする
		if time_left <= 0.0 and multiplayer.is_server():
			finish_game()

	game_process(delta)
	# game_process の中で別の画面に切りかわったら、ここで終わり
	if not is_inside_tree():
		return

	# CPUを考えさせるのはホストだけ
	if multiplayer.is_server() and state == "play":
		for p in players.values():
			if p.is_bot and not p.out:
				bot_think(p, delta)


## カメラを、自分のキャラの斜め上うしろに動かす
func _place_camera(t: float) -> void:
	var focus := Vector3.ZERO
	var me: Node = players.get(local_key)
	if me and not me.out:
		focus = me.global_position
		me.cam_yaw = cam_yaw
	else:
		# 自分がいない・脱落した → 残っている人の真ん中を見る(観戦モード)
		var alive := []
		for p in players.values():
			if not p.out:
				alive.append(p.global_position)
		if alive.size() > 0:
			for a in alive:
				focus += a
			focus /= alive.size()
		_orbit += get_process_delta_time() * 0.15
		if alive.is_empty() or players.is_empty():
			cam_yaw = _orbit
	var offset := Vector3(0, cam_height, cam_distance).rotated(Vector3.UP, cam_yaw)
	cam.global_position = cam.global_position.lerp(focus + offset, t)
	cam.look_at(focus + Vector3(0, 1.0, 0))


# ─────────── カウントダウン・点数・結果 ───────────

func _countdown() -> void:
	state = "ready"
	_set_all_can_move(false)
	time_left = game_time
	timer_label.text = str(int(game_time))
	for n in [3, 2, 1]:
		show_big(str(n))
		await get_tree().create_timer(0.9, false).timeout
		if not is_inside_tree():
			return
	show_big("スタート!", Color("#ffd166"))
	state = "play"
	_set_all_can_move(true)
	on_start()
	await get_tree().create_timer(0.8, false).timeout
	if is_inside_tree() and big_label.text == "スタート!":
		show_big("")


func _set_all_can_move(value: bool) -> void:
	for p in players.values():
		p.can_move = value


## 点数を足す(ホストだけが点数を決め、全員に配る)
func add_score(k: String, amount: int) -> void:
	if multiplayer.is_server() and scores.has(k):
		set_score.rpc(k, scores[k] + amount)


@rpc("authority", "call_local", "reliable")
func set_score(k: String, value: int) -> void:
	scores[k] = value
	refresh_scores()


## ゲーム終了(ホストが呼ぶ)
func finish_game() -> void:
	if state == "result":
		return
	state = "result"
	show_results.rpc(scores, result_header())


@rpc("authority", "call_local", "reliable")
func show_results(final_scores: Dictionary, header: String) -> void:
	state = "result"
	scores = final_scores
	_set_all_can_move(false)
	if OS.get_cmdline_user_args().size() > 0:   # 自動テストのときだけ記録を出す
		print("RESULT peer=%d game=%s %s %s" % [multiplayer.get_unique_id(), game_title, header, final_scores])
	show_big("")
	timer_label.text = ""

	# 点数の高い順(または低い順)に並べる
	var order := scores.keys()
	order.sort_custom(func(a, b): return scores[a] > scores[b] if higher_is_better else scores[a] < scores[b])

	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", _panel_style(Color(0.08, 0.09, 0.2, 0.92)))
	panel.set_anchors_preset(Control.PRESET_CENTER)
	panel.grow_horizontal = Control.GROW_DIRECTION_BOTH
	panel.grow_vertical = Control.GROW_DIRECTION_BOTH
	hud.add_child(panel)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 10)
	panel.add_child(box)
	box.add_child(make_label(header, 44, Color("#ffd166")))
	var rank := 0
	var last_score = null
	for i in order.size():
		var k = order[i]
		if scores[k] != last_score:
			rank = i + 1
			last_score = scores[k]
		var p: Node = players.get(k)
		var who: String = p.display_name if p else k
		var col: Color = p.color if p else Color.WHITE
		var medal: String = ["", "1位", "2位", "3位"][rank] if rank <= 3 else "%d位" % rank
		box.add_child(make_label("%s   %s   %s" % [medal, who, score_text(scores[k])], 30, col.lightened(0.25)))
	box.add_child(make_label("まもなく広場に戻ります", 20, Color(1, 1, 1, 0.7)))

	# 勝った人のキャラをぴょんぴょんさせる
	if order.size() > 0 and players.has(order[0]):
		var winner: Node = players[order[0]]
		var tw := create_tween().set_loops(6)
		tw.tween_property(winner, "scale", Vector3(1.3, 1.3, 1.3), 0.25)
		tw.tween_property(winner, "scale", Vector3.ONE, 0.25)

	if multiplayer.is_server():
		await get_tree().create_timer(7.0, false).timeout
		if is_inside_tree():
			main.back_to_hub()


## 点数の表示のしかた(ゲームごとに変えられる)
func score_text(value: int) -> String:
	return "%d 点" % value


## 右上の点数表を作り直す
func refresh_scores() -> void:
	if not score_box:
		return
	for c in score_box.get_children():
		c.queue_free()
	var order := scores.keys()
	order.sort_custom(func(a, b): return scores[a] > scores[b] if higher_is_better else scores[a] < scores[b])
	for k in order:
		var p: Node = players.get(k)
		if not p:
			continue
		var text := "%s  %s" % [p.display_name, score_text(scores[k])]
		if p.out:
			text += "  (脱落)"
		score_box.add_child(make_label(text, 22, p.color.lightened(0.25)))


## 画面の真ん中に大きく文字を出す
func show_big(text: String, color := Color.WHITE) -> void:
	big_label.text = text
	big_label.modulate = color
	if text != "":
		big_label.pivot_offset = big_label.size / 2.0
		big_label.scale = Vector2(1.5, 1.5)
		create_tween().tween_property(big_label, "scale", Vector2.ONE, 0.25).set_trans(Tween.TRANS_BACK)


## ホストに処理を頼む。自分がホストなら、そのまま実行する
func call_host(method: String, args: Array = []) -> void:
	if multiplayer.is_server():
		callv(method, args)
	else:
		callv("rpc_id", [1, method] + args)


# ─────────── 画面の文字づくり ───────────

func _build_hud() -> void:
	var layer := CanvasLayer.new()
	add_child(layer)
	hud = Control.new()
	hud.set_anchors_preset(Control.PRESET_FULL_RECT)
	hud.mouse_filter = Control.MOUSE_FILTER_IGNORE
	layer.add_child(hud)

	var title := make_label(game_title, 30, Color("#ffd166"))
	title.position = Vector2(24, 16)
	hud.add_child(title)

	timer_label = make_label("", 56)
	timer_label.set_anchors_preset(Control.PRESET_CENTER_TOP)
	timer_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	timer_label.grow_horizontal = Control.GROW_DIRECTION_BOTH
	timer_label.position.y = 10
	hud.add_child(timer_label)

	score_box = VBoxContainer.new()
	score_box.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	score_box.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	score_box.position = Vector2(-24, 18)
	score_box.alignment = BoxContainer.ALIGNMENT_BEGIN
	hud.add_child(score_box)

	big_label = make_label("", 110)
	big_label.set_anchors_preset(Control.PRESET_FULL_RECT)
	big_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	big_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	hud.add_child(big_label)

	help_label = make_label(help_text, 20, Color(1, 1, 1, 0.85))
	help_label.set_anchors_preset(Control.PRESET_CENTER_BOTTOM)
	help_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	help_label.grow_horizontal = Control.GROW_DIRECTION_BOTH
	help_label.grow_vertical = Control.GROW_DIRECTION_BEGIN
	help_label.position.y = -16
	hud.add_child(help_label)


## ふちどりつきの文字を作る
func make_label(text: String, size := 24, color := Color.WHITE) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", color)
	l.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.8))
	l.add_theme_constant_override("outline_size", maxi(4, int(size / 6.0)))
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return l


## 角の丸い板(パネル)の見た目
func _panel_style(color: Color) -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = color
	s.set_corner_radius_all(18)
	s.content_margin_left = 36
	s.content_margin_right = 36
	s.content_margin_top = 24
	s.content_margin_bottom = 24
	return s
