extends "res://scripts/base_game.gd"
## ─────────────────────────────────────────────
## 浮島クリスタル(協力)
## ─────────────────────────────────────────────
## 夜空の浮島で、みんなで協力してクリスタルを集めます(90秒)。
##   ・クリスタルを取るとチームの数が1増える
##   ・赤いトゲ玉に当たったり島から落ちたりすると、自分が集めた数が1減る
##   ・チームで6個集めるごとにトゲ玉が1体ふえる
## ブラウザ版「浮島クリスタル」をみんなで遊べるようにしたものです。
##
## 通信のしくみ:
##   トゲ玉はホストだけが動かして、位置を全員に送ります(enemy_positions)。
##   当たったかどうかは、各自のパソコンが自分のキャラについて調べます。

const ISLAND_R := 20.0
const CRYSTAL_COUNT := 5

var _crystals := {}          # 番号 → ノード
var _next_id := 0
var _asked := {}
var _enemies := []           # トゲ玉のノード
var _enemy_vel := []         # (ホストだけ) トゲ玉の速さ
var _collected := 0          # チームで集めた合計(減らない数。レベルアップに使う)
var _level := 1
var _hurt_cool := {}         # キャラごとの、次に当たるまでの時間
var _time := 0.0
var _pillars := [Vector2(7, 5), Vector2(-8, 4), Vector2(-5, -8), Vector2(8, -7), Vector2(0, 12), Vector2(0, -13)]
var _team_label: Label


func _init() -> void:
	game_title = "浮島クリスタル"
	help_text = "みんなでクリスタルを集めよう!  トゲ玉はジャンプでとびこえられる"
	game_time = 90.0
	cam_height = 12.0
	cam_distance = 14.0


func build_world() -> void:
	Build.environment(self, Color("#05081c"), Color("#2b3a7a"), Color("#05081c"), 0.7, Vector3(-55, 40, 0))
	# 島: 草の円盤 + 下に岩
	Build.cylinder(self, ISLAND_R, 1.2, Vector3(0, -0.6, 0), Color("#3f8f6a"), 64)
	var rim := TorusMesh.new()
	rim.inner_radius = ISLAND_R - 0.15
	rim.outer_radius = ISLAND_R + 0.15
	rim.rings = 96
	Build.deco(self, rim, Build.mat(Color("#7ef0d8"), 0.2, 0.0, 3.0), Vector3(0, 0.02, 0))
	var rock := CylinderMesh.new()
	rock.top_radius = ISLAND_R
	rock.bottom_radius = 0.5
	rock.height = 16.0
	rock.radial_segments = 18
	Build.deco(self, rock, Build.mat(Color("#4a3b5c")), Vector3(0, -9.2, 0))
	# 石の柱(ぶつかる)
	for p in _pillars:
		var h := 4.0 + randf() * 3.0
		Build.cylinder(self, 1.3, h, Vector3(p.x, h / 2.0, p.y), Color("#8a86a8"), 7)
	# 星空(小さな光る点をたくさん)
	var stars := GPUParticles3D.new()
	stars.amount = 600
	stars.lifetime = 9999.0
	stars.preprocess = 1.0
	stars.explosiveness = 1.0
	var pm := ParticleProcessMaterial.new()
	pm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE_SURFACE
	pm.emission_sphere_radius = 90.0
	pm.gravity = Vector3.ZERO
	pm.initial_velocity_min = 0.0
	pm.initial_velocity_max = 0.0
	stars.process_material = pm
	var dot := SphereMesh.new()
	dot.radius = 0.25
	dot.height = 0.5
	dot.material = Build.mat(Color("#cfe0ff"), 1.0, 0.0, 4.0)
	stars.draw_pass_1 = dot
	stars.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF  # 星は影を作らない
	stars.visibility_aabb = AABB(Vector3(-100, -100, -100), Vector3(200, 200, 200))
	add_child(stars)
	# 月
	var moon := SphereMesh.new()
	moon.radius = 6.0
	moon.height = 12.0
	Build.deco(self, moon, Build.mat(Color("#fff3c4"), 1.0, 0.0, 2.5), Vector3(-40, 35, -60))


func _ready() -> void:
	super._ready()
	_team_label = make_label("チーム 0 個", 34, Color("#7ef0d8"))
	_team_label.set_anchors_preset(Control.PRESET_CENTER_TOP)
	_team_label.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_team_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_team_label.position.y = 76
	hud.add_child(_team_label)


func spawn_point(index: int) -> Vector3:
	var a := index * 1.3
	return Vector3(cos(a) * 2.5, 1.0, sin(a) * 2.5)


## 空いている場所を探す(柱の上や、だれかのすぐ近くはさける)
func _free_spot(min_dist: float) -> Vector3:
	for i in 40:
		var a := randf() * TAU
		var d := sqrt(randf()) * (ISLAND_R - 2.5)
		var spot := Vector3(cos(a) * d, 0, sin(a) * d)
		var ok := true
		for p in _pillars:
			if Vector2(spot.x, spot.z).distance_to(p) < 2.6:
				ok = false
		for pl in players.values():
			if pl.global_position.distance_to(spot) < min_dist:
				ok = false
		if ok:
			return spot
	return Vector3.ZERO


func on_start() -> void:
	if multiplayer.is_server():
		for i in CRYSTAL_COUNT:
			_host_spawn_crystal()
		_host_spawn_enemy()


func _host_spawn_crystal() -> void:
	_next_id += 1
	spawn_crystal.rpc(_next_id, _free_spot(4.0) + Vector3(0, 1.2, 0))


@rpc("authority", "call_local", "reliable")
func spawn_crystal(id: int, pos: Vector3) -> void:
	var gem := SphereMesh.new()
	gem.radius = 0.6
	gem.height = 1.5
	gem.radial_segments = 4   # 角を4つにすると宝石の形になる
	gem.rings = 1
	var node := Build.deco(self, gem, Build.mat(Color("#ffd66b"), 0.15, 0.4, 1.2), pos)
	var light := OmniLight3D.new()
	light.light_color = Color("#ffd66b")
	light.omni_range = 3.5
	light.light_energy = 1.2
	node.add_child(light)
	_crystals[id] = node


@rpc("any_peer", "call_remote", "reliable")
func request_crystal(id: int, k: String) -> void:
	if not _crystals.has(id) or state != "play":
		return
	add_score(k, 1)
	remove_crystal.rpc(id)
	_host_spawn_crystal()
	_collected += 1
	if _collected % 6 == 0:
		_level += 1
		_host_spawn_enemy()
		announce.rpc("レベル %d! トゲ玉がふえた" % _level)


@rpc("authority", "call_local", "reliable")
func remove_crystal(id: int) -> void:
	if not _crystals.has(id):
		return
	var node: Node3D = _crystals[id]
	_crystals.erase(id)
	var tw := create_tween()
	tw.tween_property(node, "scale", Vector3(2, 2, 2), 0.15)
	tw.tween_property(node, "scale", Vector3.ZERO, 0.15)
	tw.tween_callback(node.queue_free)


@rpc("authority", "call_local", "reliable")
func announce(text: String) -> void:
	show_big(text, Color("#ffd66b"))
	await get_tree().create_timer(1.2).timeout
	if is_inside_tree() and big_label.text == text:
		show_big("")


# ───── トゲ玉 ─────

func _host_spawn_enemy() -> void:
	var spot := _free_spot(10.0)
	add_enemy.rpc(spot + Vector3(0, 0.9, 0))


@rpc("authority", "call_local", "reliable")
func add_enemy(pos: Vector3) -> void:
	var e := Node3D.new()
	e.position = pos
	add_child(e)
	var ball := SphereMesh.new()
	ball.radius = 0.8
	ball.height = 1.6
	var red := Build.mat(Color("#ff6b5a"), 0.5, 0.0, 0.4)
	Build.deco(e, ball, red, Vector3.ZERO)
	# トゲ: 円すいを14本、いろいろな向きにつける
	for i in 14:
		var dir := Vector3(randf() * 2 - 1, randf() * 2 - 1, randf() * 2 - 1).normalized()
		var spike := CylinderMesh.new()
		spike.top_radius = 0.0
		spike.bottom_radius = 0.2
		spike.height = 0.7
		var s := Build.deco(e, spike, red, dir * 0.95)
		s.quaternion = Quaternion(Vector3.UP, dir)
	_enemies.append(e)
	_enemy_vel.append(Vector3.ZERO)


## ホストから全員へ: トゲ玉の位置
@rpc("authority", "call_remote", "unreliable_ordered")
func enemy_positions(list: PackedVector3Array) -> void:
	for i in mini(list.size(), _enemies.size()):
		_enemies[i].position = _enemies[i].position.lerp(list[i], 0.5)


func game_process(delta: float) -> void:
	_time += delta
	for id in _crystals:
		var c: Node3D = _crystals[id]
		c.rotation.y += delta * 2.0
		c.position.y = 1.2 + sin(_time * 3.0 + id) * 0.25
	for e in _enemies:
		e.rotate_y(delta * 2.0)
	if _team_label:
		var total := 0
		for v in scores.values():
			total += v
		_team_label.text = "チーム %d 個   レベル %d" % [total, _level]
	if state != "play":
		return
	if multiplayer.is_server():
		_move_enemies(delta)
	_check_touches()


## ホスト: トゲ玉を、一番近いプレイヤーに向かって動かす
func _move_enemies(delta: float) -> void:
	var speed := 3.0 + _level * 0.5
	var list := PackedVector3Array()
	for i in _enemies.size():
		var e: Node3D = _enemies[i]
		var target: Node = null
		var best := INF
		for p in players.values():
			var d: float = p.global_position.distance_to(e.position)
			if d < best and p.global_position.y > -1.0:
				best = d
				target = p
		var want := Vector3.ZERO
		if target:
			want = (target.global_position - e.position)
			want.y = 0
			want = want.normalized() * speed
			# まっすぐすぎないように、ゆらゆらさせる
			want = want.rotated(Vector3.UP, sin(_time * 1.3 + i) * 0.5)
		# ほかのトゲ玉と重ならないように離れる
		for j in _enemies.size():
			if j != i:
				var away: Vector3 = e.position - _enemies[j].position
				away.y = 0
				if away.length() < 2.4 and away.length() > 0.01:
					want += away.normalized() * 3.0
		_enemy_vel[i] = _enemy_vel[i].lerp(want, minf(1.0, 2.0 * delta))
		e.position += _enemy_vel[i] * delta
		# 島の外や柱の中に入らないようにする
		var flat := Vector2(e.position.x, e.position.z)
		if flat.length() > ISLAND_R - 1.0:
			flat = flat.normalized() * (ISLAND_R - 1.0)
		for p in _pillars:
			var diff: Vector2 = flat - p
			if diff.length() < 2.2:
				flat = p + diff.normalized() * 2.2
		e.position.x = flat.x
		e.position.z = flat.y
		list.append(e.position)
	if Net.online:
		enemy_positions.rpc(list)


## 自分の担当のキャラが、クリスタルやトゲ玉にさわったか調べる
func _check_touches() -> void:
	for p in players.values():
		if not p.is_multiplayer_authority():
			continue
		var pos: Vector3 = p.global_position
		for id in _crystals.keys():
			if not _asked.has(id) and pos.distance_to(_crystals[id].position - Vector3(0, 0.6, 0)) < 1.3:
				_asked[id] = true
				call_host("request_crystal", [id, p.key])
		var cool: float = _hurt_cool.get(p.key, 0.0) - get_process_delta_time()
		_hurt_cool[p.key] = cool
		if cool > 0.0:
			continue
		for e in _enemies:
			var diff: Vector3 = pos - e.position
			if Vector2(diff.x, diff.z).length() < 1.4 and pos.y < 1.6:
				_hurt_cool[p.key] = 2.0
				var push := Vector3(diff.x, 0, diff.z).normalized() * 14.0
				push.y = 8.0
				p.send_hit(push)
				call_host("lose_one", [p.key])
				break


## ホスト: 当たった人の数を1つ減らす
@rpc("any_peer", "call_remote", "reliable")
func lose_one(k: String) -> void:
	if scores.has(k) and scores[k] > 0 and state == "play":
		set_score.rpc(k, scores[k] - 1)


func on_player_fell(p: Node) -> void:
	p.teleport(Vector3(0, 6, 0))
	call_host("lose_one", [p.key])


## 協力ゲームなので、チームの合計を見出しにする
func result_header() -> String:
	var total := 0
	for v in scores.values():
		total += v
	var rank := "すごい!" if total >= 30 else ("いいね!" if total >= 15 else "おつかれさま!")
	return "チームで %d 個  %s" % [total, rank]


func score_text(value: int) -> String:
	return "%d 個" % value
