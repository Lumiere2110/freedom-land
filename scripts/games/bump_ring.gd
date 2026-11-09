extends "res://scripts/base_game.gd"
## ─────────────────────────────────────────────
## ぶつかりリング(対戦・サバイバル)
## ─────────────────────────────────────────────
## 丸いリングの上で、ダッシュでぶつかって相手を外に押し出します。
## リングは時間がたつほど小さくなります。落ちたら脱落。
## 最後まで残った人が勝ち。点数 = 生き残った順位のポイントです。
##
## 通信のしくみ:
##   落ちたかどうかは、そのキャラの担当のパソコンが調べて、ホストに伝えます(report_out)。
##   ホストは脱落した順番を記録して、全員に「この人は脱落」と配ります(mark_out)。

const START_RADIUS := 13.0   # 最初のリングの大きさ
const END_RADIUS := 4.5      # いちばん小さくなったときの大きさ

var _ring_body: StaticBody3D
var _ring_mesh: CylinderMesh
var _ring_shape: CylinderShape3D
var _edge: MeshInstance3D
var _radius := START_RADIUS
var _out_order := []         # 脱落した順番(ホストが使う)
var _reported := {}


func _init() -> void:
	game_title = "ぶつかりリング"
	help_text = "ダッシュ(Shift)で相手を押し出そう! 落ちたら脱落   リングはだんだん小さくなる"
	game_time = 75.0


func build_world() -> void:
	Build.environment(self, Color("#1d2b64"), Color("#f8cdda"), Color("#0b0f2a"), 1.0, Vector3(-60, -30, 0))
	_ring_body = Build.cylinder(self, START_RADIUS, 2.0, Vector3(0, -1.0, 0), Color("#f4f1de"), 64)
	var mi: MeshInstance3D = _ring_body.get_child(0)
	_ring_mesh = mi.mesh
	_ring_shape = _ring_body.get_child(1).shape
	# リングのふちの光る線(ここから外は危ない)
	var edge := TorusMesh.new()
	edge.inner_radius = 0.95
	edge.outer_radius = 1.0
	edge.rings = 64
	_edge = Build.deco(self, edge, Build.mat(Color("#ff5d73"), 0.2, 0.0, 3.0), Vector3(0, 0.02, 0))
	_edge.scale = Vector3(START_RADIUS, 1, START_RADIUS)
	# 真ん中のマーク
	var mark := CylinderMesh.new()
	mark.top_radius = 2.0
	mark.bottom_radius = 2.0
	mark.height = 0.02
	Build.deco(self, mark, Build.mat(Color("#e07a5f")), Vector3(0, 0.01, 0))
	# 下にはるか遠く見える雲の海
	var sea := BoxMesh.new()
	sea.size = Vector3(300, 1, 300)
	Build.deco(self, sea, Build.mat(Color("#e9d8f4"), 1.0), Vector3(0, -30, 0))
	# まわりに浮かぶ飾りの柱
	for i in 10:
		var a := TAU * i / 10.0
		var pillar := CylinderMesh.new()
		pillar.top_radius = 0.6
		pillar.bottom_radius = 0.6
		pillar.height = 8.0
		Build.deco(self, pillar, Build.mat(Color("#81b29a"), 0.5), Vector3(cos(a) * 22, -2, sin(a) * 22))
		var orb := SphereMesh.new()
		orb.radius = 0.8
		orb.height = 1.6
		Build.deco(self, orb, Build.mat(Net.COLORS[i % 8], 0.2, 0.0, 2.0), Vector3(cos(a) * 22, 2.8, sin(a) * 22))


func spawn_point(index: int) -> Vector3:
	var a := TAU * index / maxf(1.0, participants.size())
	return Vector3(cos(a) * 8.0, 1.0, sin(a) * 8.0)


func game_process(delta: float) -> void:
	if state == "play":
		# 残り時間にあわせてリングを小さくする
		var t := clampf(1.0 - time_left / game_time, 0.0, 1.0)
		_radius = lerpf(START_RADIUS, END_RADIUS, t)
		_ring_mesh.top_radius = _radius
		_ring_mesh.bottom_radius = _radius
		_ring_shape.radius = _radius
		_edge.scale = Vector3(_radius, 1, _radius)
	# 自分の担当のキャラが落ちたか調べる
	for p in players.values():
		if p.is_multiplayer_authority() and not p.out and not _reported.has(p.key) and p.global_position.y < -3.0:
			_reported[p.key] = true
			call_host("report_out", [p.key])


## 落ちたとき(下のほうまで落ちたらもう見えなくする)
func on_player_fell(p: Node) -> void:
	p.set_out(true)


## ホスト: 脱落を記録する
@rpc("any_peer", "call_remote", "reliable")
func report_out(k: String) -> void:
	if _out_order.has(k) or not players.has(k):
		return
	_out_order.append(k)
	# 早く落ちた人ほど点数が低い(1番に落ちたら0点)
	set_score.rpc(k, _out_order.size() - 1)
	mark_out.rpc(k)
	_check_end()


@rpc("authority", "call_local", "reliable")
func mark_out(k: String) -> void:
	if players.has(k):
		var p: Node = players[k]
		p.can_move = false
		show_big("%s 脱落!" % p.display_name, p.color.lightened(0.3))
		get_tree().create_timer(1.0, false).timeout.connect(func():
			if not is_inside_tree():
				return
			p.set_out(true)   # 落ちていくところを見せてから消す
			if big_label.text.ends_with("脱落!"):
				show_big(""))
	refresh_scores()


## ホスト: 残りが1人(ひとり用なら0人)になったら終わり
func _check_end() -> void:
	var alive := []
	for k in players.keys():
		if not _out_order.has(k):
			alive.append(k)
	if alive.size() <= 1:
		finish_game()


## 終わったとき、残っていた人に生き残りポイントをあげる
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
	if players.has(best):
		return "%s の勝ち!" % players[best].display_name
	return "結果発表"


func score_text(value: int) -> String:
	return "%d pt" % value


## CPU: 一番近い相手を追いかけてダッシュ。ふちに近づきすぎたら真ん中へ戻る
func bot_think(bot: Node, _delta: float) -> void:
	var pos: Vector3 = bot.global_position
	var flat := Vector2(pos.x, pos.z)
	if flat.length() > _radius - Net.cpu_value(1.0, 2.0, 2.5):   # つよいCPUほど、ふちに近づかない
		bot.ai_move = -flat.normalized()
		bot.ai_dash = false
		return
	var target: Node = null
	var best := INF
	for o in players.values():
		if o == bot or o.out:
			continue
		var d: float = o.global_position.distance_to(pos)
		if d < best:
			best = d
			target = o
	if target == null:
		bot.ai_move = Vector2.ZERO
		return
	# 相手の「外側」に回りこんでから押すと、外に押し出しやすい
	var tp: Vector3 = target.global_position
	var aim := Vector2(tp.x, tp.z) * 0.85
	var to := aim - flat
	bot.ai_move = to.normalized()
	bot.ai_dash = best < 3.2 and randf() < Net.cpu_value(0.02, 0.06, 0.12)
