extends "res://scripts/base_game.gd"
## ─────────────────────────────────────────────
## ぐるぐるバー(対戦・サバイバル)
## ─────────────────────────────────────────────
## 丸い台の真ん中から、長いバーがぐるぐる回ってきます。
## タイミングよくジャンプしてとびこえよう! 当たると台の外へ飛ばされます。
##   ・バーはだんだん速くなる
##   ・25秒たつと、反対側から2本目のバーが出てくる
##   ・落ちたら脱落。最後まで残った人の勝ち
##
## 通信のしくみ:
##   バーの角度は「スタートしてからの時間」だけで決まるので、
##   通信しなくても全員のパソコンで同じ動きになります。
##   当たったかどうかは、キャラの担当のパソコンが調べます。
##   脱落の記録は、ぶつかりリングと同じくホストが行います。

const RADIUS := 9.0          # 台の大きさ
const BAR_HEIGHT := 0.55     # バーの高さ(これより高くジャンプすればよけられる)
const START_SPEED := 1.1     # 最初の回る速さ(1秒に何ラジアン回るか)
const SPEED_UP := 0.035      # 1秒ごとに速くなる量
const SECOND_BAR_TIME := 25.0

var _bars := []              # 回るバー(Node3D)
var _elapsed := 0.0          # スタートしてからの時間
var _hit_cool := {}          # キャラごとの、次に当たるまでの時間
var _out_order := []
var _reported := {}


func _init() -> void:
	game_title = "ぐるぐるバー"
	help_text = "回ってくるバーをジャンプ(Space)でとびこえよう! 当たると飛ばされる"
	game_time = 80.0
	cam_height = 11.0
	cam_distance = 13.0


func build_world() -> void:
	Build.environment(self, Color("#3a1c71"), Color("#ffaf7b"), Color("#1a0b33"), 1.1, Vector3(-55, 30, 0))
	# 台: 2色の輪を重ねてターゲットのような模様に
	Build.cylinder(self, RADIUS, 1.0, Vector3(0, -0.5, 0), Color("#ffe8d6"), 64)
	for i in 3:
		var ring := CylinderMesh.new()
		var r := RADIUS * (0.8 - i * 0.25)
		ring.top_radius = r
		ring.bottom_radius = r
		ring.height = 0.02
		ring.radial_segments = 64
		var c := Color("#ffb4a2") if i % 2 == 0 else Color("#ffe8d6")
		Build.deco(self, ring, Build.mat(c), Vector3(0, 0.01 + i * 0.005, 0))
	# 真ん中の柱(バーの軸)
	Build.cylinder(self, 0.7, 2.0, Vector3(0, 1.0, 0), Color("#6d597a"))
	var cap := SphereMesh.new()
	cap.radius = 0.8
	cap.height = 1.6
	Build.deco(self, cap, Build.mat(Color("#ffd166"), 0.3, 0.2, 1.5), Vector3(0, 2.1, 0))
	# 台の下(はるか下に雲)
	var sea := BoxMesh.new()
	sea.size = Vector3(300, 1, 300)
	Build.deco(self, sea, Build.mat(Color("#f6bd9b"), 1.0), Vector3(0, -35, 0))
	# まわりに浮かぶ輪っかの飾り
	for i in 8:
		var a := TAU * i / 8.0
		var deco_ring := TorusMesh.new()
		deco_ring.inner_radius = 1.0
		deco_ring.outer_radius = 1.3
		var node := Build.deco(self, deco_ring, Build.mat(Net.COLORS[i], 0.2, 0.0, 1.5), Vector3(cos(a) * 17, 3.0 + sin(i) * 1.5, sin(a) * 17))
		node.rotation = Vector3(PI / 2, -a, 0)
	# バーを2本作っておく(2本目は最初は見せない)
	for i in 2:
		_bars.append(_make_bar(i))
	_bars[1].visible = false


## 回るバーを1本作る。軸(pivot)を回すと、バーが真ん中を中心に回る
func _make_bar(index: int) -> Node3D:
	var pivot := Node3D.new()
	add_child(pivot)
	var bar := BoxMesh.new()
	bar.size = Vector3(RADIUS + 0.5, 0.45, 0.45)
	var color := Color("#ef476f") if index == 0 else Color("#118ab2")
	Build.deco(pivot, bar, Build.mat(color, 0.3, 0.1, 0.6), Vector3((RADIUS + 0.5) / 2.0, BAR_HEIGHT, 0))
	# バーの先のしましま(回っているのがわかりやすいように)
	var tip := SphereMesh.new()
	tip.radius = 0.4
	tip.height = 0.8
	Build.deco(pivot, tip, Build.mat(Color.WHITE, 0.2, 0.0, 2.0), Vector3(RADIUS + 0.5, BAR_HEIGHT, 0))
	return pivot


func spawn_point(index: int) -> Vector3:
	var a := TAU * index / maxf(1.0, participants.size()) + PI / 3.0
	return Vector3(cos(a) * 5.5, 1.0, sin(a) * 5.5)


## 今のバーの角度(ラジアン)。時間だけで決まる
func _bar_angle(i: int) -> float:
	var base := START_SPEED * _elapsed + 0.5 * SPEED_UP * _elapsed * _elapsed
	return base + (PI if i == 1 else 0.0)


func _bar_active(i: int) -> bool:
	return i == 0 or _elapsed >= SECOND_BAR_TIME


func game_process(delta: float) -> void:
	if state == "play":
		_elapsed += delta
	for i in _bars.size():
		# rotation.y をマイナスにすると、バーが (cos 角度, sin 角度) の向きを指す
		_bars[i].rotation.y = -_bar_angle(i)
		if i == 1 and _bar_active(1) and not _bars[1].visible:
			_bars[1].visible = true
			show_big("2本目のバー!", Color("#118ab2"))
			get_tree().create_timer(1.0).timeout.connect(func():
				if is_inside_tree() and big_label.text == "2本目のバー!":
					show_big(""))
	if state != "play":
		return
	for p in players.values():
		if not p.is_multiplayer_authority() or p.out:
			continue
		_check_bar_hit(p, delta)
		if p.global_position.y < -3.0 and not _reported.has(p.key):
			_reported[p.key] = true
			call_host("report_out", [p.key])


## バーに当たったか調べる(担当のパソコンで)
func _check_bar_hit(p: Node, delta: float) -> void:
	var cool: float = _hit_cool.get(p.key, 0.0) - delta
	_hit_cool[p.key] = cool
	if cool > 0.0:
		return
	var pos: Vector3 = p.global_position
	var r := Vector2(pos.x, pos.z).length()
	if r > RADIUS + 0.6 or r < 0.5 or pos.y > BAR_HEIGHT + 0.25:
		return  # 台の外・真ん中・ジャンプ中は当たらない
	var my_angle := atan2(pos.z, pos.x)
	for i in _bars.size():
		if not _bar_active(i):
			continue
		var a := _bar_angle(i)
		var diff := wrapf(a - my_angle, -PI, PI)
		var half_width := 0.7 / r   # バーの太さ+キャラの太さを、角度に直したもの
		if absf(diff) < half_width:
			# バーが進む向き(円の接線)に、外向きを少し足して飛ばす
			var along := Vector3(-sin(a), 0, cos(a))
			var outward := Vector3(pos.x, 0, pos.z).normalized()
			var push := (along * 1.0 + outward * 0.6).normalized() * 19.0
			push.y = 7.0
			p.send_hit(push)
			_hit_cool[p.key] = 0.8
			return


func on_player_fell(p: Node) -> void:
	p.set_out(true)


## ホスト: 脱落を記録する
@rpc("any_peer", "call_remote", "reliable")
func report_out(k: String) -> void:
	if _out_order.has(k) or not players.has(k):
		return
	_out_order.append(k)
	set_score.rpc(k, _out_order.size() - 1)
	mark_out.rpc(k)
	var alive := 0
	for key in players.keys():
		if not _out_order.has(key):
			alive += 1
	if alive <= 1:
		finish_game()


@rpc("authority", "call_local", "reliable")
func mark_out(k: String) -> void:
	if not players.has(k):
		return
	var p: Node = players[k]
	p.can_move = false
	show_big("%s 脱落!" % p.display_name, p.color.lightened(0.3))
	refresh_scores()


func finish_game() -> void:
	if state == "result":
		return
	if multiplayer.is_server():
		var alive := []
		for k in players.keys():
			if not _out_order.has(k):
				alive.append(k)
		for k in alive:
			scores[k] = players.size() if alive.size() == 1 else _out_order.size()
	super.finish_game()


func result_header() -> String:
	var best := ""
	var top := -1
	for k in scores.keys():
		if scores[k] > top:
			top = scores[k]
			best = k
	return "%s の勝ち!" % players[best].display_name if players.has(best) else "結果発表"


func score_text(value: int) -> String:
	return "%d pt" % value


## CPU: 台の真ん中あたりをうろうろして、バーが近づいてきたらジャンプする
func bot_think(bot: Node, _delta: float) -> void:
	var pos: Vector3 = bot.global_position
	var flat := Vector2(pos.x, pos.z)
	var r := flat.length()
	# 動く目標: 半径4〜6くらいの円の上をゆっくり回る
	if not bot.has_meta("goal_angle"):
		bot.set_meta("goal_angle", randf() * TAU)
	var ga: float = bot.get_meta("goal_angle") + 0.004
	bot.set_meta("goal_angle", ga)
	var goal := Vector2(cos(ga), sin(ga)) * 5.0
	var to := goal - flat
	bot.ai_move = to.normalized() if to.length() > 0.8 else Vector2.ZERO
	if r > RADIUS - 1.5:
		bot.ai_move = -flat.normalized()
	# バーが「もうすぐ来る」ならジャンプ。CPUごとに反応の速さを少し変える
	bot.ai_jump = false
	var my_angle := atan2(pos.z, pos.x)
	var reaction: float = 0.25 + float(hash(bot.key) % 10) * 0.03
	for i in _bars.size():
		if not _bar_active(i):
			continue
		var ahead := wrapf(my_angle - _bar_angle(i), -PI, PI)   # バーが自分に届くまでの角度
		var speed := START_SPEED + SPEED_UP * _elapsed
		if ahead > 0.0 and ahead / speed < reaction and randf() < 0.9:
			bot.ai_jump = true
	bot.ai_dash = false
