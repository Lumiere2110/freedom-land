extends "res://scripts/base_game.gd"
## ─────────────────────────────────────────────
## Bond(ボンド・チーム戦 5対5のレーンバトル)
## ─────────────────────────────────────────────
## 青チームと赤チームに分かれて戦います。マップには3本の道(レーン)があります。
##   ・上レーンに2人、下レーンに2人、中央レーンにエース1人
##   ・こうげきボタンで、近くの敵に光の玉を飛ばす(いちばん近い敵をねらう)
##   ・敵をたおすとチームに1点。エースをたおすと2点
##   ・たおされたキャラは数秒で自分の基地から復活する
##   ・自分の基地の中にいると体力が回復し、敵の基地に入ると体力がへる
##   ・時間切れのときに点数が多いチームの勝ち
##
## 通信のしくみ:
##   こうげきボタンを押すと、担当のパソコンが「この敵をうちたい」とホストに伝えます(request_attack)。
##   ホストが距離などを確かめてから体力をへらし、全員に配ります(do_attack / set_hp)。
##   体力・得点・復活はぜんぶホストが決めるので、パソコンごとに結果がずれません。

const LANE_Z := {"top": -16.0, "ace": 0.0, "bottom": 16.0}   # レーンの位置(z)
const ROLES := ["ace", "top", "top", "bottom", "bottom"]       # チームの中の役わり(入った順)
const ROLE_NAMES := {"ace": "エース(中央)", "top": "上レーン", "bottom": "下レーン"}
const TEAM_NAMES := ["青チーム", "赤チーム"]
const TEAM_COLORS := [Color("#4cc9f0"), Color("#ff5d73")]

const MAP_X := 48.0          # マップの横の半分
const MAP_Z := 24.0          # マップのたての半分
const BASE_X := 36.0         # これより外側が基地
const RESPAWN_TIME := 5.0    # 復活までの秒数
const BASE_HEAL := 30.0      # 自分の基地での回復(1秒あたり)
const BASE_HURT := 40.0      # 敵の基地でのダメージ(1秒あたり)

var uses_attack := true      # スマホの「こうげき」ボタンを出す合図(touch_controls.gd が見る)

var team := {}               # キャラの名前 → 0(青) か 1(赤)
var role := {}               # キャラの名前 → "ace" / "top" / "bottom"
var hp := {}                 # キャラの名前 → 今の体力
var max_hp := {}
var team_points := [0, 0]

var _bars := {}              # キャラの名前 → 体力バー(前の板)
var _cool := {}              # こうげきの待ち時間(このパソコンで動かすキャラ)
var _last_attack := {}       # ホスト: 最後にこうげきを受けつけた時刻
var _dead_until := {}        # ホスト: キャラの名前 → 復活する時刻
var _clock := 0.0
var _tick := 0.0
var _my_respawn := 0.0       # 自分が復活するまでの残り秒数(表示用)
var _team_label: Label
var _feed: VBoxContainer     # 「〇〇 が △△ をたおした」の表示


func _init() -> void:
	game_title = "Bond"
	help_text = "敵をたおしてチームに得点! こうげき J / F (コントローラー B)  エースをたおすと2点"
	game_time = 150.0
	cam_height = 21.0
	cam_distance = 15.0


func _ready() -> void:
	super._ready()
	_build_team_hud()


# ─────────── チーム分け ───────────

## i番目の参加者のチーム(交互に 青・赤)と役わり
func _team_of(index: int) -> int:
	return index % 2

func _role_of(index: int) -> String:
	return ROLES[(index / 2) % ROLES.size()]


## キャラを作るときに、チームの色・体力バー・エースの王冠をつける
func spawn_player(info: Dictionary, index: int) -> Node:
	var t := _team_of(index)
	var r := _role_of(index)
	var data := info.duplicate()
	data["color"] = TEAM_COLORS[t].lerp(Color.WHITE, 0.1 * (index / 2))
	var k: String = info["key"]
	team[k] = t
	role[k] = r
	max_hp[k] = 150 if r == "ace" else 100
	hp[k] = max_hp[k]
	var p: Node = super.spawn_player(data, index)
	_decorate(p)
	return p


func _decorate(p: Node) -> void:
	var k: String = p.key
	var mine: bool = k == local_key
	# 足もとの輪: チームの色(自分は金色)
	var ring := TorusMesh.new()
	ring.inner_radius = 0.6
	ring.outer_radius = 0.78
	var ring_color: Color = Color("#ffd166") if mine else TEAM_COLORS[team[k]]
	Build.deco(p, ring, Build.mat(ring_color, 0.3, 0.0, 1.2), Vector3(0, 0.06, 0)).scale = Vector3(1, 0.3, 1)
	# 自分には、こうげきが届く範囲をうすく表示する
	if mine:
		var reach := TorusMesh.new()
		reach.inner_radius = _range(k) - 0.06
		reach.outer_radius = _range(k)
		reach.rings = 64
		var m := Build.mat(Color(1, 1, 1, 0.35), 1.0)
		m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		Build.deco(p, reach, m, Vector3(0, 0.05, 0)).scale = Vector3(1, 0.05, 1)
	# エースは頭に王冠
	if role[k] == "ace":
		var crown := CylinderMesh.new()
		crown.top_radius = 0.32
		crown.bottom_radius = 0.26
		crown.height = 0.22
		Build.deco(p, crown, Build.mat(Color("#ffd166"), 0.2, 0.8, 0.6), Vector3(0, 1.48, 0))
	# 体力バー(いつもカメラのほうを向く板を2枚重ねる)
	var back := _bar_quad(Vector2(1.3, 0.18), Color(0, 0, 0, 0.6), 0)
	back.position.y = 2.25
	p.add_child(back)
	var front := _bar_quad(Vector2(1.24, 0.12), TEAM_COLORS[team[k]].lightened(0.2), 1)
	front.position.y = 2.25
	p.add_child(front)
	_bars[k] = front


func _bar_quad(size: Vector2, color: Color, priority: int) -> MeshInstance3D:
	var q := QuadMesh.new()
	q.size = size
	var m := StandardMaterial3D.new()
	m.albedo_color = color
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	m.billboard_keep_scale = true
	m.no_depth_test = true
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.render_priority = priority
	var mi := MeshInstance3D.new()
	mi.mesh = q
	mi.material_override = m
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return mi


## スタート位置・復活する場所: 自分の基地の、自分のレーンの近く
func spawn_point(index: int) -> Vector3:
	return _base_spot(_team_of(index), _role_of(index), index / 2)


func _base_spot(t: int, r: String, slot: int) -> Vector3:
	var side := -1.0 if t == 0 else 1.0
	var z: float = LANE_Z[r] * 0.8 + (2.5 if slot % 2 == 0 else 0.0) * signf(LANE_Z[r])
	return Vector3(side * (42.0 - (slot % 2) * 2.0), 1.0, z)


func _spot_of(k: String) -> Vector3:
	var slot := 0
	for i in participants.size():
		if participants[i]["key"] == k:
			slot = i / 2
	return _base_spot(team.get(k, 0), role.get(k, "ace"), slot)


# ─────────── ステージ ───────────

func build_world() -> void:
	Build.environment(self, Color("#4a90e2"), Color("#d6f0ff"), Color("#2d4a3e"), 1.2, Vector3(-60, 20, 0))
	# 地面(芝生)
	Build.box(self, Vector3(MAP_X * 2 + 2, 1, MAP_Z * 2 + 2), Vector3(0, -0.5, 0), Color("#6fbf73"))
	# 3本のレーン(土の道)
	for r in LANE_Z:
		var strip := BoxMesh.new()
		strip.size = Vector3(MAP_X * 2 - 8, 0.04, 6.0 if r == "ace" else 5.0)
		Build.deco(self, strip, Build.mat(Color("#e9d8a6")), Vector3(0, 0.02, LANE_Z[r]))
		Build.text3d(self, ["上レーン", "中央レーン", "下レーン"][["top", "ace", "bottom"].find(r)],
			Vector3(0, 0.3, LANE_Z[r] - 2.2), 120, Color(1, 1, 1, 0.75)).rotation_degrees.x = -90
	# レーンとレーンの間の茂み(かべ)。ところどころに通り道がある
	var segments := [[-30.0, -18.0], [-12.0, -3.0], [3.0, 12.0], [18.0, 30.0]]
	for z in [-8.0, 8.0]:
		for s in segments:
			var seg_len: float = s[1] - s[0]
			var w := Build.box(self, Vector3(seg_len, 2.2, 2.0), Vector3((s[0] + s[1]) / 2.0, 1.1, z), Color("#2f7d4f"))
			w.get_child(0).material_override = Build.mat(Color("#2f7d4f"), 0.9)
		# 通り道の目印の木
		for x in [-30.0, 30.0]:
			Build.tree(self, Vector3(x, 0, z), 1.2)
	# 外がわの低いかべ
	for side in [-1, 1]:
		Build.box(self, Vector3(MAP_X * 2 + 2, 1.4, 1), Vector3(0, 0.7, side * (MAP_Z + 0.5)), Color("#8d6e63"))
		Build.box(self, Vector3(1, 1.4, MAP_Z * 2 + 2), Vector3(side * (MAP_X + 0.5), 0.7, 0), Color("#8d6e63"))
	# 基地(青は左、赤は右)
	for t in 2:
		var side := -1.0 if t == 0 else 1.0
		var c: Color = TEAM_COLORS[t]
		var pad := BoxMesh.new()
		pad.size = Vector3(MAP_X - BASE_X, 0.06, MAP_Z * 2)
		var pm := Build.mat(c.darkened(0.35), 0.8)
		Build.deco(self, pad, pm, Vector3(side * (BASE_X + MAP_X) / 2.0, 0.03, 0))
		# 基地のさかい目の光る線
		var line := BoxMesh.new()
		line.size = Vector3(0.3, 0.08, MAP_Z * 2)
		Build.deco(self, line, Build.mat(c, 0.2, 0.0, 2.0), Vector3(side * BASE_X, 0.05, 0))
		Build.text3d(self, TEAM_NAMES[t] + "の基地", Vector3(side * 42.0, 6.8, 0), 90, c.lightened(0.3))
		# 基地のシンボル(光る柱)
		Build.cylinder(self, 0.8, 4.0, Vector3(side * 46.0, 2.0, 0), c.darkened(0.2))
		var orb := SphereMesh.new()
		orb.radius = 0.9
		orb.height = 1.8
		Build.deco(self, orb, Build.mat(c, 0.2, 0.0, 2.5), Vector3(side * 46.0, 4.8, 0))
	# 外の飾り
	for i in 20:
		var x := -MAP_X + i * (MAP_X * 2 / 19.0)
		Build.tree(self, Vector3(x, -0.5, -MAP_Z - 4.0), 1.4)
		Build.tree(self, Vector3(x, -0.5, MAP_Z + 4.0), 1.4)
	Build.box(self, Vector3(160, 1, 120), Vector3(0, -1.6, 0), Color("#4f9d55"))


# ─────────── こうげき ───────────

func _range(k: String) -> float:
	return 9.0 if role.get(k, "") == "ace" else 8.0

func _damage(k: String) -> int:
	return 25 if role.get(k, "") == "ace" else 18

func _cooldown(k: String) -> float:
	return 0.5 if role.get(k, "") == "ace" else 0.55


## k の、こうげきが届く中でいちばん近い敵(いなければ null)
func _nearest_enemy(k: String, max_dist: float) -> Node:
	var me: Node = players.get(k)
	if not me:
		return null
	var best: Node = null
	var best_d := max_dist
	for o in players.values():
		if o.out or team.get(o.key, -1) == team[k]:
			continue
		var d: float = o.global_position.distance_to(me.global_position)
		if d <= best_d:
			best_d = d
			best = o
	return best


## こうげきしてみる(このキャラの担当のパソコンで呼ぶ)
func _try_attack(p: Node) -> void:
	if _cool.get(p.key, 0.0) > 0.0 or p.out or state != "play":
		return
	var target := _nearest_enemy(p.key, _range(p.key))
	if not target:
		return
	_cool[p.key] = _cooldown(p.key)
	call_host("request_attack", [p.key, target.key])


## ホスト: こうげきを受けつける
@rpc("any_peer", "call_remote", "reliable")
func request_attack(k: String, target_k: String) -> void:
	if state != "play" or not players.has(k) or not players.has(target_k):
		return
	var a: Node = players[k]
	var b: Node = players[target_k]
	# 自分のキャラ以外を勝手に動かせないようにする
	var sender := multiplayer.get_remote_sender_id()
	if sender != 0 and sender != a.get_multiplayer_authority():
		return
	if a.out or b.out or team[k] == team[target_k]:
		return
	if a.global_position.distance_to(b.global_position) > _range(k) + 2.0:
		return   # 通信のおくれを考えて、少しだけ遠くても OK
	if _clock - _last_attack.get(k, -99.0) < _cooldown(k) * 0.8:
		return
	_last_attack[k] = _clock
	do_attack.rpc(k, target_k)
	_hurt(target_k, _damage(k), k)


## 全員: 光の玉が飛んでいく見た目
@rpc("authority", "call_local", "reliable")
func do_attack(k: String, target_k: String) -> void:
	if not players.has(k) or not players.has(target_k):
		return
	var a: Node = players[k]
	var b: Node = players[target_k]
	var ball := SphereMesh.new()
	ball.radius = 0.28 if role.get(k, "") == "ace" else 0.2
	ball.height = ball.radius * 2.0
	var shot := Build.deco(self, ball, Build.mat(TEAM_COLORS[team[k]].lightened(0.4), 0.2, 0.0, 3.0), a.global_position + Vector3(0, 1.0, 0))
	var tw := create_tween()
	tw.tween_property(shot, "global_position", b.global_position + Vector3(0, 0.8, 0), 0.16)
	tw.tween_property(shot, "scale", Vector3(2.5, 2.5, 2.5), 0.08)
	tw.tween_callback(shot.queue_free)


## ホスト: 体力をへらす。0 になったらたおれる
func _hurt(k: String, amount: float, by: String) -> void:
	if not hp.has(k) or players[k].out:
		return
	var v := maxf(0.0, hp[k] - amount)
	set_hp.rpc(k, v)
	if v <= 0.0:
		_defeat(k, by)


@rpc("authority", "call_local", "reliable")
func set_hp(k: String, value: float) -> void:
	hp[k] = value
	if _bars.has(k):
		var bar: Node3D = _bars[k]
		bar.scale.x = maxf(0.01, value / float(max_hp[k]))


## ホスト: たおれたときの得点と、復活の予約
func _defeat(k: String, by: String) -> void:
	var t: int = team[k]
	var pts := 2 if role[k] == "ace" else 1
	team_points[1 - t] += pts
	if by != "" and scores.has(by):
		add_score(by, 1)
	_dead_until[k] = _clock + RESPAWN_TIME
	mark_dead.rpc(k, by, pts, team_points)


@rpc("authority", "call_local", "reliable")
func mark_dead(k: String, by: String, pts: int, points: Array) -> void:
	team_points = points
	_update_team_label()
	if OS.get_cmdline_user_args().size() > 0:   # 自動テストのときだけ記録を出す
		print("KILL peer=%d %s by %s points=%s" % [multiplayer.get_unique_id(), k, by, points])
	if not players.has(k):
		return
	var p: Node = players[k]
	# たおれたところで、ぱっと光る
	var burst := SphereMesh.new()
	burst.radius = 0.6
	burst.height = 1.2
	var fx := Build.deco(self, burst, Build.mat(Color.WHITE, 0.2, 0.0, 3.0), p.global_position + Vector3(0, 0.8, 0))
	var tw := create_tween()
	tw.tween_property(fx, "scale", Vector3(3, 3, 3), 0.3)
	tw.tween_callback(fx.queue_free)
	p.set_out(true)
	refresh_scores()
	var who: String = players[by].display_name if players.has(by) else "基地"
	_add_feed("%s が %s をたおした  +%d" % [who, p.display_name, pts], TEAM_COLORS[1 - team[k]].lightened(0.3))
	if k == local_key:
		_my_respawn = RESPAWN_TIME


## 全員: 復活
@rpc("authority", "call_local", "reliable")
func respawn(k: String) -> void:
	if not players.has(k):
		return
	var p: Node = players[k]
	hp[k] = max_hp[k]
	set_hp(k, max_hp[k])
	if p.is_multiplayer_authority():
		p.teleport(_spot_of(k))
	p.set_out(false)
	p.can_move = state == "play"
	refresh_scores()
	if k == local_key:
		_my_respawn = 0.0
		show_big("")


# ─────────── 毎フレーム ───────────

func game_process(delta: float) -> void:
	for k in _cool.keys():
		_cool[k] -= delta
	# 自分がたおれているとき: 復活までの秒数
	if _my_respawn > 0.0:
		_my_respawn -= delta
		var text := "復活まで %d" % maxi(1, ceili(_my_respawn))
		if big_label.text != text:
			show_big(text, Color(1, 1, 1, 0.9))
	if state != "play":
		return
	# 自分のキャラのこうげき
	var me: Node = players.get(local_key)
	if me and Input.is_action_just_pressed("attack"):
		_try_attack(me)
	if not multiplayer.is_server():
		return
	_clock += delta
	# 復活の時間になったキャラを復活させる
	for k in _dead_until.keys():
		if _clock >= _dead_until[k]:
			_dead_until.erase(k)
			respawn.rpc(k)
	# 基地で回復・ダメージ(0.25秒ごと)
	_tick += delta
	if _tick >= 0.25:
		for p in players.values():
			if p.out:
				continue
			var x: float = p.global_position.x
			var own := (x < -BASE_X) if team[p.key] == 0 else (x > BASE_X)
			var enemy := (x > BASE_X) if team[p.key] == 0 else (x < -BASE_X)
			if own and hp[p.key] < max_hp[p.key]:
				set_hp.rpc(p.key, minf(max_hp[p.key], hp[p.key] + BASE_HEAL * _tick))
			elif enemy:
				_hurt(p.key, BASE_HURT * _tick, "")
		_tick = 0.0


## 落ちたら(ふつうは落ちないけれど)基地に戻す
func on_player_fell(p: Node) -> void:
	p.teleport(_spot_of(p.key))


## たおれている間は、自分の基地を映す
func _place_camera(t: float) -> void:
	var me: Node = players.get(local_key)
	if me and me.out and team.has(local_key):
		var focus := _spot_of(local_key)
		var offset := Vector3(0, cam_height, cam_distance).rotated(Vector3.UP, cam_yaw)
		cam.global_position = cam.global_position.lerp(focus + offset, t)
		cam.look_at(focus + Vector3(0, 1.0, 0))
	else:
		super._place_camera(t)


# ─────────── CPU ───────────

## CPU: 自分のレーンを進み、敵が近ければうつ。体力が少ないと基地に帰る
func bot_think(bot: Node, delta: float) -> void:
	var k: String = bot.key
	var t: int = team[k]
	var side := 1.0 if t == 0 else -1.0       # 敵の基地のある向き(x)
	var pos: Vector3 = bot.global_position
	var lane_z: float = LANE_Z[role[k]]
	bot.ai_jump = false
	bot.ai_dash = false
	_cool[k] = _cool.get(k, 0.0)

	# 体力が少ないときは基地へ帰る(よわいCPUは帰らない)
	var retreat_at := Net.cpu_value(0.0, 0.3, 0.4)
	if bot.get_meta("retreat", false) or hp[k] < max_hp[k] * retreat_at:
		bot.set_meta("retreat", hp[k] < max_hp[k] * 0.95)
		_walk_to(bot, Vector3(-side * 42.0, 0, lane_z * 0.8))
		return

	# 近くの敵(同じレーンのあたりにいる敵)をさがす
	var target: Node = null
	var best := 13.0
	for o in players.values():
		if o.out or team[o.key] == t:
			continue
		var d: float = o.global_position.distance_to(pos)
		var same_area := absf(o.global_position.z - pos.z) < 7.0 or absf(pos.x) > 30.0
		# 敵の基地の中までは追いかけない(基地の中では体力がへるので)
		var in_their_base: bool = (o.global_position.x > BASE_X) if t == 0 else (o.global_position.x < -BASE_X)
		if in_their_base:
			continue
		if d < best and same_area:
			best = d
			target = o
	if target:
		var r := _range(k)
		var to: Vector3 = target.global_position - pos
		if best > r * 0.85:
			bot.ai_move = Vector2(to.x, to.z).normalized()
			bot.ai_dash = best > r + 2.0 and randf() < Net.cpu_value(0.0, 0.01, 0.03)
		elif best < r * 0.5:
			bot.ai_move = -Vector2(to.x, to.z).normalized()   # 近すぎたら少し下がる
		else:
			# 横に少し動いて、よけながらうつ
			var strafe := Vector2(-to.z, to.x).normalized() * (1.0 if int(_clock * 0.7 + hash(k)) % 2 == 0 else -1.0)
			bot.ai_move = strafe * 0.6
		# よわいCPUほど、うつ間かくが長い
		if _cool[k] <= 0.0 and best <= r:
			_try_attack(bot)
			_cool[k] += Net.cpu_value(0.9, 0.35, 0.05)
		return

	# 敵がいなければ、自分のレーンを敵の基地のほうへ進む(敵の基地の手前で止まる)
	var front := side * (BASE_X - 4.0)
	if absf(pos.z - lane_z) > 2.0 and (absf(pos.x) > 31.0 or absf(lane_z) < 1.0 or signf(pos.z) == signf(lane_z)):
		# まだレーンに入っていない: レーンのほうへ
		_walk_to(bot, Vector3(pos.x + side * 2.0, 0, lane_z))
	elif side * (front - pos.x) > 1.0:
		_walk_to(bot, Vector3(front, 0, lane_z))
	else:
		bot.ai_move = Vector2.ZERO


func _walk_to(bot: Node, goal: Vector3) -> void:
	var to: Vector3 = goal - bot.global_position
	to.y = 0
	bot.ai_move = Vector2(to.x, to.z).normalized() if to.length() > 0.8 else Vector2.ZERO


# ─────────── 画面の文字 ───────────

func _build_team_hud() -> void:
	_team_label = make_label("", 40)
	_team_label.set_anchors_preset(Control.PRESET_CENTER_TOP)
	_team_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_team_label.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_team_label.position.y = 76
	hud.add_child(_team_label)
	_feed = VBoxContainer.new()
	_feed.position = Vector2(24, 70)
	hud.add_child(_feed)
	# 自分の役わりを表示
	if role.has(local_key):
		var mine := make_label("あなた: %s %s" % [TEAM_NAMES[team[local_key]], ROLE_NAMES[role[local_key]]], 22,
			TEAM_COLORS[team[local_key]].lightened(0.3))
		mine.set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
		mine.grow_vertical = Control.GROW_DIRECTION_BEGIN
		mine.position = Vector2(24, -60)
		hud.add_child(mine)
	_update_team_label()


func _update_team_label() -> void:
	if _team_label:
		_team_label.text = "青 %d  -  %d 赤" % [team_points[0], team_points[1]]


func _add_feed(text: String, color: Color) -> void:
	if not _feed:
		return
	var l := make_label(text, 20, color)
	_feed.add_child(l)
	while _feed.get_child_count() > 4:
		var old := _feed.get_child(0)
		_feed.remove_child(old)
		old.queue_free()
	get_tree().create_timer(4.0, false).timeout.connect(func():
		if is_instance_valid(l):
			l.queue_free())


func result_header() -> String:
	var a: int = team_points[0]
	var b: int = team_points[1]
	if a == b:
		return "引き分け!  %d 対 %d" % [a, b]
	return "%sの勝ち!  %d 対 %d" % [TEAM_NAMES[0 if a > b else 1], a, b]


func score_text(value: int) -> String:
	return "%d たおした" % value


## 右上の表: チームごとに、たおした数の多い順。たおれている人は「復活待ち」
func refresh_scores() -> void:
	if not score_box:
		return
	for c in score_box.get_children():
		c.queue_free()
	for t in 2:
		var order := []
		for k in scores.keys():
			if team.get(k, -1) == t and players.has(k):
				order.append(k)
		order.sort_custom(func(a, b): return scores[a] > scores[b])
		for k in order:
			var p: Node = players[k]
			var text := "%s  %s" % [p.display_name, score_text(scores[k])]
			if p.out:
				text += " (復活待ち)"
			score_box.add_child(make_label(text, 18, TEAM_COLORS[t].lightened(0.3)))
