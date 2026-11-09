extends "res://scripts/base_game.gd"
## ─────────────────────────────────────────────
## コインラッシュ(対戦)
## ─────────────────────────────────────────────
## 60秒のあいだに、ステージに出てくるコインを集めます。
##   ・ふつうのコイン = 1点、金の大コイン = 5点
##   ・ダッシュで相手にぶつけると、相手のコインを2枚落とさせる
##
## 通信のしくみ:
##   コインを出す・消すのはホストの仕事です。
##   自分のキャラがコインにさわったら、ホストに「取ったよ」と伝え(request_coin)、
##   ホストが本当にまだあるか確かめてから、全員に「消して」と配ります(remove_coin)。
##   こうすると、2人が同時に取っても点数が二重にならずにすみます。

const ARENA := 15.0          # ステージの半分の広さ
const COIN_COUNT := 14       # 同時に出ているコインの数

var _coins := {}             # コイン番号 → { "node", "value" }
var _next_id := 0
var _spin := 0.0
var _asked := {}             # 自分が「取ったよ」と送ったコイン(何度も送らないため)


func _init() -> void:
	game_title = "コインラッシュ"
	help_text = "コインを集めよう! 金の大コインは5点   ダッシュ(Shift)でぶつかると相手のコインを落とす"
	game_time = 60.0


func build_world() -> void:
	Build.environment(self, Color("#ff9a8b"), Color("#ffe29f"), Color("#5b3a6e"), 1.2, Vector3(-40, 60, 0))
	# 床: 市松模様(2色のタイル)
	for x in range(-3, 3):
		for z in range(-3, 3):
			var c := Color("#ffe8b0") if (x + z) % 2 == 0 else Color("#ffd28a")
			Build.box(self, Vector3(5, 1, 5), Vector3(x * 5 + 2.5, -0.5, z * 5 + 2.5), c)
	# まわりの壁
	for side in [-1, 1]:
		Build.box(self, Vector3(ARENA * 2 + 1, 1.2, 1), Vector3(0, 0.6, side * (ARENA + 0.5)), Color("#e76f51"))
		Build.box(self, Vector3(1, 1.2, ARENA * 2 + 1), Vector3(side * (ARENA + 0.5), 0.6, 0), Color("#e76f51"))
	# 乗れる台(高いところにもコインが出る)
	var blocks := [
		[Vector3(-8, 0.75, -8), Vector3(4, 1.5, 4)], [Vector3(8, 0.75, 8), Vector3(4, 1.5, 4)],
		[Vector3(8, 1.25, -8), Vector3(3, 2.5, 3)], [Vector3(-8, 1.25, 8), Vector3(3, 2.5, 3)],
		[Vector3(0, 0.5, 0), Vector3(6, 1.0, 6)], [Vector3(0, 2.0, 0), Vector3(2.5, 1.0, 2.5)],
	]
	for b in blocks:
		Build.box(self, b[1], b[0], Color("#2a9d8f"))
	# ステージの外の飾り
	for i in 16:
		var a := TAU * i / 16.0
		Build.tree(self, Vector3(cos(a) * 24, -0.5, sin(a) * 24), 1.6)
	Build.box(self, Vector3(80, 1, 80), Vector3(0, -1.6, 0), Color("#90be6d"))


func spawn_point(index: int) -> Vector3:
	var corners := [Vector3(-12, 1, -12), Vector3(12, 1, 12), Vector3(12, 1, -12), Vector3(-12, 1, 12)]
	return corners[index % 4] + Vector3(0, 0, (index / 4) * 2.0)


## スタートしたら、ホストがコインを出す
func on_start() -> void:
	if multiplayer.is_server():
		for i in COIN_COUNT:
			_host_spawn_coin()


## ホスト: コインを1枚、空いている場所に出して全員に知らせる
func _host_spawn_coin() -> void:
	var value := 5 if randf() < 0.12 else 1
	var pos := Vector3(randf_range(-ARENA + 1.5, ARENA - 1.5), 1.0, randf_range(-ARENA + 1.5, ARENA - 1.5))
	# 台の上なら、そこまで高くする
	var space := get_world_3d().direct_space_state
	var q := PhysicsRayQueryParameters3D.create(pos + Vector3(0, 10, 0), pos + Vector3(0, -5, 0), 1)
	var hit := space.intersect_ray(q)
	if hit:
		pos.y = hit["position"].y + 1.0
	_next_id += 1
	spawn_coin.rpc(_next_id, pos, value)


## 全員: コインを作る
@rpc("authority", "call_local", "reliable")
func spawn_coin(id: int, pos: Vector3, value: int) -> void:
	var big := value > 1
	var node := Build.deco(self, Build.coin_mesh(0.75 if big else 0.45),
		Build.mat(Color("#ffb703") if big else Color("#ffd166"), 0.2, 0.9, 0.8 if big else 0.35), pos, Vector3(PI / 2, 0, 0))
	if big:
		var light := OmniLight3D.new()
		light.light_color = Color("#ffb703")
		light.omni_range = 3.0
		node.add_child(light)
	node.scale = Vector3.ZERO
	create_tween().tween_property(node, "scale", Vector3.ONE, 0.3).set_trans(Tween.TRANS_BACK)
	_coins[id] = {"node": node, "value": value}


## 自分のキャラ: 「このコインを取ったよ」とホストに伝える(ホストで実行される)
@rpc("any_peer", "call_remote", "reliable")
func request_coin(id: int, player_key: String) -> void:
	if not _coins.has(id) or state != "play":
		return
	add_score(player_key, _coins[id]["value"])
	remove_coin.rpc(id)
	_host_spawn_coin()


## 全員: コインを消す(キラッと光って消える)
@rpc("authority", "call_local", "reliable")
func remove_coin(id: int) -> void:
	if not _coins.has(id):
		return
	var node: Node3D = _coins[id]["node"]
	_coins.erase(id)
	var tw := create_tween()
	tw.tween_property(node, "position:y", node.position.y + 1.5, 0.25)
	tw.parallel().tween_property(node, "scale", Vector3(1.6, 1.6, 1.6), 0.25)
	tw.tween_callback(node.queue_free)


func game_process(delta: float) -> void:
	_spin += delta * 3.0
	for c in _coins.values():
		c["node"].rotation.y = _spin
	if state != "play":
		return
	# 自分が担当しているキャラ(自分とCPU)がコインにさわったか調べる
	for p in players.values():
		if not p.is_multiplayer_authority() or p.out:
			continue
		for id in _coins.keys():
			var node: Node3D = _coins[id]["node"]
			if not _asked.has(id) and p.global_position.distance_to(node.position - Vector3(0, 0.4, 0)) < 1.1:
				_asked[id] = true
				call_host("request_coin", [id, p.key])


## ダッシュで相手に当てたら、相手は2枚落とす(ホストが計算)
func on_player_hit(victim: Node, attacker: Node) -> void:
	call_host("steal", [victim.key, attacker.key])


@rpc("any_peer", "call_remote", "reliable")
func steal(victim_key: String, _attacker_key: String) -> void:
	if state != "play" or not scores.has(victim_key):
		return
	var lose := mini(2, scores[victim_key])
	if lose <= 0:
		return
	set_score.rpc(victim_key, scores[victim_key] - lose)
	# 落としたコインを近くにまき散らす
	var at: Vector3 = players[victim_key].global_position
	for i in lose:
		_next_id += 1
		var pos := at + Vector3(randf_range(-2.5, 2.5), 0.6, randf_range(-2.5, 2.5))
		pos.x = clampf(pos.x, -ARENA + 1, ARENA - 1)
		pos.z = clampf(pos.z, -ARENA + 1, ARENA - 1)
		spawn_coin.rpc(_next_id, pos, 1)


## CPU: いちばん近いコインに向かう。高いところならジャンプ
func bot_think(bot: Node, _delta: float) -> void:
	var best: Node3D = null
	var best_d := INF
	for c in _coins.values():
		var d: float = bot.global_position.distance_to(c["node"].position) / (2.0 if c["value"] > 1 else 1.0)
		if d < best_d:
			best_d = d
			best = c["node"]
	if best == null:
		bot.ai_move = Vector2.ZERO
		return
	var to: Vector3 = best.position - bot.global_position
	bot.ai_move = Vector2(to.x, to.z).normalized()
	bot.ai_jump = to.y > 0.8 and Vector2(to.x, to.z).length() < 4.0
	# たまに近くの相手にダッシュでぶつかりに行く
	bot.ai_dash = false
	for o in players.values():
		if o != bot and not o.out and o.global_position.distance_to(bot.global_position) < 2.5 and randf() < Net.cpu_value(0.005, 0.02, 0.04):
			var d2: Vector3 = o.global_position - bot.global_position
			bot.ai_move = Vector2(d2.x, d2.z).normalized()
			bot.ai_dash = true


func score_text(value: int) -> String:
	return "%d 枚" % value
