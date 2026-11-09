extends CharacterBody3D
## ─────────────────────────────────────────────
## Player(プレイヤーのキャラクター)
## ─────────────────────────────────────────────
## 1人ぶんのキャラクターです。自分のキャラも、ほかの人のキャラも、CPUも
## 全部このスクリプトで動いています。
##
## 「だれが動かすか」の決まり:
##   ・自分のキャラ → 自分のパソコンでキー入力を読んで動かす
##   ・ほかの人のキャラ → その人のパソコンから届いた位置に合わせて動かす
##   ・CPU(bot) → ホストのパソコンが考えて動かす
##   Godot ではこれを「マルチプレイヤー・オーソリティ(担当者)」と呼びます。
##   is_multiplayer_authority() が true なら「このキャラの担当は自分」です。

const Build = preload("res://scripts/build.gd")

# ───── 動きの強さ(ここを変えると操作感が変わります) ─────
const SPEED := 7.5          # 歩く速さ
const JUMP_POWER := 9.5     # ジャンプの高さ
const GRAVITY := 26.0       # 重力(大きいほど早く落ちる)
const DASH_SPEED := 17.0    # ダッシュの速さ
const DASH_TIME := 0.22     # ダッシュが続く時間(秒)
const DASH_COOLDOWN := 0.9  # 次にダッシュできるまでの時間(秒)
const HIT_POWER := 15.0     # ダッシュでぶつかったときに相手を飛ばす強さ
const BODY_RADIUS := 0.45   # キャラの太さ

# ───── このキャラの情報(ゲームが作るときに入れる) ─────
var key := ""               # キャラの名前(ノード名と同じ)
var display_name := ""      # 画面に出す名前
var color := Color.WHITE    # キャラの色
var is_bot := false         # CPUなら true
var game: Node = null       # 今いるゲーム(base_game.gd)

# ───── 状態 ─────
var can_move := true        # false の間は動けない(カウントダウン中など)
var out := false            # 脱落したら true
var cam_yaw := 0.0          # カメラの向き。「前」がどちらかを決める
var ai_move := Vector2.ZERO # CPUが行きたい方向
var ai_jump := false        # CPUがジャンプしたいか
var ai_dash := false        # CPUがダッシュしたいか

var _dash_left := 0.0
var _dash_cool := 0.0
var _dash_dir := Vector3.ZERO
var _knock := Vector3.ZERO  # ぶつけられて飛ばされている勢い
var _hit_list := []         # 今回のダッシュですでに当てた相手
var _invincible := 0.0      # ぶつけられた直後の無敵時間
var _target_pos := Vector3.ZERO   # ほかの人のキャラ:届いた位置
var _target_rot := 0.0
var _remote_dashing := false
var _walk_time := 0.0

# 見た目のパーツ
var _visual: Node3D
var _body_mesh: MeshInstance3D
var _trail: GPUParticles3D


func _ready() -> void:
	# 当たり判定のグループ分け:
	#   レイヤー1 = 地面や壁、レイヤー2 = キャラ
	#   キャラは地面(1)にだけぶつかり、キャラ同士はすり抜ける(押し合いは自分で計算)
	collision_layer = 2
	collision_mask = 1
	floor_snap_length = 0.3
	_build_body()
	_target_pos = global_position


## キャラの見た目を作る(体・目・ほっぺ・名前)
func _build_body() -> void:
	var shape := CapsuleShape3D.new()
	shape.radius = BODY_RADIUS
	shape.height = 1.3
	var cs := CollisionShape3D.new()
	cs.shape = shape
	cs.position.y = 0.65
	add_child(cs)

	_visual = Node3D.new()
	add_child(_visual)

	# 体: 少しつぶれた丸いカプセル
	var body := CapsuleMesh.new()
	body.radius = 0.5
	body.height = 1.35
	_body_mesh = Build.deco(_visual, body, Build.mat(color, 0.45), Vector3(0, 0.68, 0))

	# 目(白目+黒目)を顔の前(-Z方向)につける
	for side in [-1, 1]:
		var white := SphereMesh.new()
		white.radius = 0.13
		white.height = 0.26
		Build.deco(_visual, white, Build.mat(Color.WHITE, 0.3), Vector3(0.17 * side, 0.92, -0.42))
		var pupil := SphereMesh.new()
		pupil.radius = 0.07
		pupil.height = 0.14
		Build.deco(_visual, pupil, Build.mat(Color("#1d1d2c"), 0.2), Vector3(0.17 * side, 0.92, -0.53))
		var cheek := SphereMesh.new()
		cheek.radius = 0.08
		cheek.height = 0.05
		Build.deco(_visual, cheek, Build.mat(Color(1, 0.55, 0.6), 0.6), Vector3(0.3 * side, 0.74, -0.38))

	# 頭の上の名前
	var label := Build.text3d(self, display_name, Vector3(0, 1.85, 0), 40, color.lightened(0.3))
	label.no_depth_test = true

	# ダッシュ中に出るキラキラ
	_trail = GPUParticles3D.new()
	_trail.amount = 24
	_trail.lifetime = 0.35
	_trail.emitting = false
	_trail.position.y = 0.6
	var pm := ParticleProcessMaterial.new()
	pm.direction = Vector3(0, 1, 0)
	pm.spread = 180.0
	pm.initial_velocity_min = 0.5
	pm.initial_velocity_max = 1.5
	pm.gravity = Vector3.ZERO
	pm.scale_min = 0.6
	pm.scale_max = 1.0
	_trail.process_material = pm
	var spark := SphereMesh.new()
	spark.radius = 0.1
	spark.height = 0.2
	spark.material = Build.mat(color.lightened(0.4), 0.2, 0.0, 2.0)
	_trail.draw_pass_1 = spark
	add_child(_trail)


func _physics_process(delta: float) -> void:
	if out:
		return
	if is_multiplayer_authority():
		_move_myself(delta)
		# 自分の位置をほかの全員に送る(毎フレーム、少しくらい届かなくてもよい送り方)
		if Net.online:
			_receive_state.rpc(global_position, _visual.rotation.y, _dash_left > 0.0)
	else:
		_follow_remote(delta)
	_animate(delta)


## 自分(またはCPU)のキャラを動かす
func _move_myself(delta: float) -> void:
	# 1) 入力を読む(Vector2: x=左右, y=前後)
	var input := Vector2.ZERO
	var want_jump := false
	var want_dash := false
	if can_move:
		if is_bot:
			input = ai_move.limit_length(1.0)
			want_jump = ai_jump
			want_dash = ai_dash
		else:
			input = Input.get_vector("move_left", "move_right", "move_forward", "move_back")
			want_jump = Input.is_action_just_pressed("jump")
			want_dash = Input.is_action_just_pressed("dash")

	# 2) カメラの向きに合わせて、入力を3Dの方向に直す
	var dir := Vector3(input.x, 0, input.y).rotated(Vector3.UP, cam_yaw)
	if is_bot:
		dir = Vector3(input.x, 0, input.y)  # CPUは最初から世界の向きで考える

	# 3) ダッシュ
	_dash_cool -= delta
	_invincible -= delta
	if want_dash and _dash_cool <= 0.0:
		_dash_left = DASH_TIME
		_dash_cool = DASH_COOLDOWN
		_hit_list.clear()
		# 入力がなければ、向いている方向にダッシュ
		_dash_dir = dir.normalized() if dir.length() > 0.1 else -_visual.global_transform.basis.z
	if _dash_left > 0.0:
		_dash_left -= delta
		velocity.x = _dash_dir.x * DASH_SPEED
		velocity.z = _dash_dir.z * DASH_SPEED
		_check_dash_hits()
	else:
		# 少しずつ目標の速さに近づける(急に止まらず、なめらかに動く)
		var accel := 12.0 if is_on_floor() else 4.0
		velocity.x = lerpf(velocity.x, dir.x * SPEED, accel * delta)
		velocity.z = lerpf(velocity.z, dir.z * SPEED, accel * delta)

	# 4) 飛ばされた勢いを足す(だんだん弱くなる)
	velocity.x += _knock.x
	velocity.z += _knock.z
	_knock = _knock.move_toward(Vector3.ZERO, 40.0 * delta)

	# 5) 重力とジャンプ
	if is_on_floor():
		if want_jump:
			velocity.y = JUMP_POWER
	else:
		velocity.y -= GRAVITY * delta

	# 6) 実際に動かす(壁や床にぶつかると自動で止まる)
	move_and_slide()
	velocity.x -= _knock.x
	velocity.z -= _knock.z

	# 7) ほかのキャラと重ならないように、少し押しのける
	_push_apart()

	# 8) 進んでいる方向を向く
	var flat := Vector2(velocity.x, velocity.z)
	if flat.length() > 0.5:
		var target := atan2(-velocity.x, -velocity.z)
		_visual.rotation.y = lerp_angle(_visual.rotation.y, target, 12.0 * delta)

	# 9) 下に落ちすぎたら、ゲームに知らせる
	if global_position.y < -14.0 and game:
		game.on_player_fell(self)


## ほかのキャラと重なったら、自分のほうを少し動かして離す
func _push_apart() -> void:
	if not game:
		return
	for other in game.players.values():
		if other == self or other.out:
			continue
		var diff: Vector3 = global_position - other.global_position
		diff.y = 0
		var d := diff.length()
		var min_d := BODY_RADIUS * 2.0
		if d < min_d and d > 0.001 and absf(global_position.y - other.global_position.y) < 1.2:
			global_position += diff / d * (min_d - d) * 0.5


## ダッシュ中に、近くの相手にぶつかったか調べる
func _check_dash_hits() -> void:
	if not game:
		return
	for other in game.players.values():
		if other == self or other.out or _hit_list.has(other):
			continue
		var diff: Vector3 = other.global_position - global_position
		if diff.length() < 1.3:
			_hit_list.append(other)
			var push := Vector3(diff.x, 0, diff.z).normalized() * HIT_POWER
			push.y = 6.0
			other.send_hit(push)
			game.on_player_hit(other, self)
			_dash_left = 0.0           # 当たったらダッシュ終わり
			velocity = -push * 0.25    # 自分も少し跳ね返る


## このキャラを飛ばす。キャラの担当者のパソコンに「飛ばして」と頼む
func send_hit(push: Vector3) -> void:
	var owner_id := get_multiplayer_authority()
	if owner_id == multiplayer.get_unique_id():
		receive_hit(push)
	else:
		receive_hit.rpc_id(owner_id, push)


## 飛ばされる(担当者のパソコンで実行される)
@rpc("any_peer", "call_remote", "reliable")
func receive_hit(push: Vector3) -> void:
	if _invincible > 0.0:
		return
	_invincible = 0.5
	_knock = Vector3(push.x, 0, push.z)
	velocity.y = push.y
	_dash_left = 0.0


## 外から強制的に場所を移す(リスポーンなど)
func teleport(pos: Vector3) -> void:
	global_position = pos
	_target_pos = pos
	velocity = Vector3.ZERO
	_knock = Vector3.ZERO


## ほかの人から届いた位置を受け取る
@rpc("authority", "call_remote", "unreliable_ordered")
func _receive_state(pos: Vector3, rot: float, dashing: bool) -> void:
	_target_pos = pos
	_target_rot = rot
	_remote_dashing = dashing


## ほかの人のキャラを、届いた位置へなめらかに近づける(カクカクしないように)
func _follow_remote(delta: float) -> void:
	var to := _target_pos - global_position
	if to.length() > 6.0:
		global_position = _target_pos   # 離れすぎたら一気に移動
	else:
		global_position = global_position.lerp(_target_pos, minf(1.0, 18.0 * delta))
	velocity = to / maxf(delta, 0.001) * 0.2
	_visual.rotation.y = lerp_angle(_visual.rotation.y, _target_rot, minf(1.0, 15.0 * delta))


## 歩くとピョコピョコ、ダッシュ中はキラキラ
func _animate(delta: float) -> void:
	var speed := Vector2(velocity.x, velocity.z).length()
	var dashing := _dash_left > 0.0 if is_multiplayer_authority() else _remote_dashing
	_trail.emitting = dashing
	if speed > 1.0:
		_walk_time += delta * (10.0 + speed)
		_visual.position.y = absf(sin(_walk_time)) * 0.12
		_visual.scale = Vector3(1.0, 1.0 + sin(_walk_time * 2.0) * 0.04, 1.0)
	else:
		_visual.position.y = lerpf(_visual.position.y, 0.0, 10.0 * delta)
		_visual.scale = _visual.scale.lerp(Vector3.ONE, 10.0 * delta)
	if dashing:
		_visual.scale = Vector3(0.85, 0.9, 1.25)
	# ぶつけられた直後はチカチカ点滅
	_visual.visible = _invincible <= 0.0 or int(_invincible * 20.0) % 2 == 0


## 脱落させる(見えなくして動かなくする)
func set_out(value: bool) -> void:
	out = value
	visible = not value
	set_physics_process(true)
	if value:
		velocity = Vector3.ZERO
