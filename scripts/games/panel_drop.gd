extends "res://scripts/base_game.gd"
## ─────────────────────────────────────────────
## ぬけおちパネル(対戦・サバイバル)
## ─────────────────────────────────────────────
## 空中に、四角いパネルが2段ならんでいます。
## 乗ったパネルは少しふるえたあと、落ちてなくなります。
## 下の段まで落ちて、さらにその下に落ちたら脱落。最後まで残った人の勝ち!
##
## 通信のしくみ:
##   パネルに乗ったことに気づくのは、そのキャラの担当のパソコンです。
##   担当のパソコンがホストに「この番号のパネルに乗った」と伝え(step)、
##   ホストが全員に「このパネルを落として」と配ります(drop_panel)。

const GRID := 9            # 1段に 9×9 枚
const SIZE := 2.6          # パネル1枚の大きさ
const LAYER_Y := [0.0, -7.0]   # 段の高さ(上の段、下の段)
const SHAKE_TIME := 0.55   # 乗ってから落ちるまでの時間(秒)

var _panels := []          # 番号 → { "body", "mesh", "state" }  state: 0=ある 1=ふるえ中 2=落ちた
var _sent := {}            # 自分がもう伝えたパネル番号
var _out_order := []
var _reported := {}
var _time := 0.0


func _init() -> void:
	game_title = "ぬけおちパネル"
	help_text = "乗ったパネルは落ちる! 動き続けて最後まで残ろう   ジャンプ Space / ダッシュ Shift"
	game_time = 90.0
	cam_height = 12.0
	cam_distance = 13.0


func build_world() -> void:
	Build.environment(self, Color("#0f4c75"), Color("#bbe1fa"), Color("#1b262c"), 1.2, Vector3(-65, 20, 0))
	var colors := [[Color("#4cc9f0"), Color("#4895ef")], [Color("#f72585"), Color("#b5179e")]]
	for layer in 2:
		for x in GRID:
			for z in GRID:
				var pos := Vector3((x - (GRID - 1) / 2.0) * SIZE, LAYER_Y[layer] - 0.25, (z - (GRID - 1) / 2.0) * SIZE)
				var c: Color = colors[layer][(x + z) % 2]
				var body := Build.box(self, Vector3(SIZE - 0.12, 0.5, SIZE - 0.12), pos, c, 0.35)
				var mesh: MeshInstance3D = body.get_child(0)
				_panels.append({"body": body, "mesh": mesh, "state": 0, "home": pos, "color": c})
	# 遠くの飾り(雲のかたまり)
	for i in 14:
		var a := TAU * i / 14.0
		var cloud := SphereMesh.new()
		cloud.radius = 3.0 + randf() * 2.0
		cloud.height = cloud.radius * 1.2
		Build.deco(self, cloud, Build.mat(Color(1, 1, 1, 0.9), 1.0), Vector3(cos(a) * 34, -12 + randf() * 6, sin(a) * 34))


func spawn_point(index: int) -> Vector3:
	var a := TAU * index / maxf(1.0, participants.size()) + PI / 4.0
	return Vector3(cos(a) * 6.5, 1.0, sin(a) * 6.5)


## パネルの番号を位置から計算する(-1 = パネルなし)
func _panel_index_at(pos: Vector3) -> int:
	var layer := -1
	for l in 2:
		if absf(pos.y - LAYER_Y[l]) < 0.6:
			layer = l
	if layer < 0:
		return -1
	var x := roundi(pos.x / SIZE + (GRID - 1) / 2.0)
	var z := roundi(pos.z / SIZE + (GRID - 1) / 2.0)
	if x < 0 or x >= GRID or z < 0 or z >= GRID:
		return -1
	return layer * GRID * GRID + x * GRID + z


func game_process(delta: float) -> void:
	_time += delta
	# ふるえ中のパネルをぶるぶるさせる
	for p in _panels:
		if p["state"] == 1:
			p["mesh"].position = Vector3(sin(_time * 70.0) * 0.06, 0, cos(_time * 63.0) * 0.06)
	if state != "play":
		return
	for pl in players.values():
		if not pl.is_multiplayer_authority() or pl.out:
			continue
		# 乗っているパネルをホストに伝える
		if pl.is_on_floor():
			var idx := _panel_index_at(pl.global_position)
			if idx >= 0 and _panels[idx]["state"] == 0 and not _sent.has(idx):
				_sent[idx] = true
				call_host("step", [idx])
		# 下の段より下に落ちたら脱落
		if pl.global_position.y < LAYER_Y[1] - 4.0 and not _reported.has(pl.key):
			_reported[pl.key] = true
			call_host("report_out", [pl.key])


## ホスト: パネルが踏まれた
@rpc("any_peer", "call_remote", "reliable")
func step(idx: int) -> void:
	if idx < 0 or idx >= _panels.size() or _panels[idx]["state"] != 0:
		return
	drop_panel.rpc(idx)


## 全員: パネルをふるわせてから落とす
@rpc("authority", "call_local", "reliable")
func drop_panel(idx: int) -> void:
	var p: Dictionary = _panels[idx]
	if p["state"] != 0:
		return
	p["state"] = 1
	var mat: StandardMaterial3D = p["mesh"].material_override
	mat.albedo_color = Color("#ffd166")
	mat.emission_enabled = true
	mat.emission = Color("#ff9f1c")
	await get_tree().create_timer(SHAKE_TIME, false).timeout
	if not is_inside_tree():
		return
	p["state"] = 2
	var body: StaticBody3D = p["body"]
	body.get_child(1).disabled = true   # 当たり判定を消す(乗れなくなる)
	var tw := create_tween()
	tw.tween_property(body, "position:y", body.position.y - 12.0, 0.8).set_ease(Tween.EASE_IN).set_trans(Tween.TRANS_QUAD)
	tw.parallel().tween_property(body, "rotation", Vector3(randf() * 2, 0, randf() * 2), 0.8)
	tw.tween_callback(func(): body.visible = false)


func on_player_fell(p: Node) -> void:
	p.set_out(true)


## ホスト: 脱落を記録する(ぶつかりリングと同じしくみ)
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
	p.set_out(true)
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


## CPU: 近くの「まだ落ちていないパネル」へ動き続ける。ふるえ中のパネルはさける
func bot_think(bot: Node, _delta: float) -> void:
	var here: int = _panel_index_at(bot.global_position)
	var layer := 0 if bot.global_position.y > LAYER_Y[1] + 2.0 else 1
	if not bot.has_meta("goal") or randf() < 0.01 or _panels[bot.get_meta("goal")]["state"] != 0 or bot.get_meta("goal") == here:
		# 新しい目的地をさがす(同じ段の、少し離れた無事なパネル)
		var choices := []
		for i in range(layer * GRID * GRID, (layer + 1) * GRID * GRID):
			if _panels[i]["state"] == 0 and i != here:
				var d: float = _panels[i]["home"].distance_to(bot.global_position)
				if d > 2.0 and d < 9.0:
					choices.append(i)
		if choices.is_empty():
			bot.ai_move = Vector2.ZERO
			return
		bot.set_meta("goal", choices[randi() % choices.size()])
	var goal: Vector3 = _panels[bot.get_meta("goal")]["home"]
	var to: Vector3 = goal - bot.global_position
	bot.ai_move = Vector2(to.x, to.z).normalized()
	# 目の前のパネルがなければジャンプでとびこえる
	var ahead: Vector3 = bot.global_position + Vector3(bot.ai_move.x, 0, bot.ai_move.y) * 1.6
	ahead.y = LAYER_Y[layer]
	var a_idx := _panel_index_at(ahead)
	bot.ai_jump = a_idx >= 0 and _panels[a_idx]["state"] == 2 and randf() < Net.cpu_value(0.2, 0.5, 0.9)
	bot.ai_dash = false
