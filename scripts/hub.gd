extends "res://scripts/base_game.gd"
## ─────────────────────────────────────────────
## Hub(広場)
## ─────────────────────────────────────────────
## みんなが集まる丸い広場です。まわりに4つの「ポータル(光る門)」があり、
## ホストがポータルに入ると、そのミニゲームが全員で始まります。
## 広場では時間制限も点数もなく、自由に歩き回れます。

const PORTAL_RADIUS := 17.0   # 広場の中心からポータルまでの距離
const PLAZA_RADIUS := 26.0    # 広場の大きさ

var _portals := []            # [{ "id", "pos", "ring" }]
var _info_label: Label
var _hint_label: Label
var _player_list: VBoxContainer
var _live := false            # タイトルの背景なら false(人がいない)
var _time := 0.0


func _ready() -> void:
	is_hub = true
	game_title = "Freedom Land 広場"
	help_text = "ポータルに入るとゲームが始まります(ホストのみ)   ダッシュ Shift / ジャンプ Space / カメラ Q・E"
	cam_distance = 14.0
	cam_height = 10.0
	_live = participants.size() > 0
	super._ready()   # 土台(base_game.gd)の準備を先にする
	if not _live:
		# タイトル画面の背景: 文字を隠して、カメラを遠くから回す
		hud.visible = false
		cam_distance = 30.0
		cam_height = 16.0
		return
	_build_hub_ui()
	sync_players_with_net()


## 広場を作る
func build_world() -> void:
	Build.environment(self, Color("#5aa9ff"), Color("#ffd6e8"), Color("#3a5f8a"), 1.3)

	# 地面: 芝生の大きな円 + 石畳の輪
	Build.cylinder(self, PLAZA_RADIUS, 1.0, Vector3(0, -0.5, 0), Color("#7bd389"), 64)
	var path := TorusMesh.new()
	path.inner_radius = PORTAL_RADIUS - 2.2
	path.outer_radius = PORTAL_RADIUS + 2.2
	path.rings = 64
	Build.deco(self, path, Build.mat(Color("#f2e3c6")), Vector3(0, -0.95, 0)).scale = Vector3(1, 0.1, 1)
	# 島の下の岩(空に浮かんでいる感じ)
	var rock := CylinderMesh.new()
	rock.top_radius = PLAZA_RADIUS
	rock.bottom_radius = 4.0
	rock.height = 14.0
	rock.radial_segments = 20
	var rock_mat := Build.mat(Color("#8d6e63"))
	rock_mat.shading_mode = BaseMaterial3D.SHADING_MODE_PER_VERTEX
	Build.deco(self, rock, rock_mat, Vector3(0, -8.0, 0))

	# まん中の噴水
	Build.cylinder(self, 3.4, 0.8, Vector3(0, 0.4, 0), Color("#e9ecf5"))
	var water := CylinderMesh.new()
	water.top_radius = 3.0
	water.bottom_radius = 3.0
	water.height = 0.1
	Build.deco(self, water, Build.mat(Color(0.35, 0.75, 1.0, 0.8), 0.05, 0.2, 0.3), Vector3(0, 0.82, 0))
	Build.cylinder(self, 0.5, 2.6, Vector3(0, 1.3, 0), Color("#e9ecf5"))
	var top := SphereMesh.new()
	top.radius = 0.9
	top.height = 1.0
	Build.deco(self, top, Build.mat(Color(0.5, 0.85, 1.0, 0.85), 0.05, 0.0, 0.6), Vector3(0, 2.8, 0))
	# 噴水の水しぶき
	var splash := GPUParticles3D.new()
	splash.amount = 120
	splash.lifetime = 1.2
	splash.position = Vector3(0, 3.0, 0)
	var pm := ParticleProcessMaterial.new()
	pm.direction = Vector3(0, 1, 0)
	pm.spread = 25.0
	pm.initial_velocity_min = 4.0
	pm.initial_velocity_max = 6.0
	pm.gravity = Vector3(0, -12, 0)
	splash.process_material = pm
	var drop := SphereMesh.new()
	drop.radius = 0.07
	drop.height = 0.14
	drop.material = Build.mat(Color(0.7, 0.9, 1.0), 0.1, 0.0, 1.0)
	splash.draw_pass_1 = drop
	add_child(splash)

	# 木と街灯をまわりに並べる
	for i in 18:
		var a := TAU * i / 18.0 + 0.17
		var r := PLAZA_RADIUS - 2.5 + randf() * 1.0
		Build.tree(self, Vector3(cos(a) * r, 0, sin(a) * r), 1.0 + randf() * 0.6)
	for i in 8:
		var a := TAU * i / 8.0 + PI / 8.0
		Build.lamp(self, Vector3(cos(a) * (PORTAL_RADIUS - 4.5), 0, sin(a) * (PORTAL_RADIUS - 4.5)))

	# 落ちないように、広場のふちに見えない壁を置く(低い柵も見せる)
	for i in 48:
		var a := TAU * i / 48.0
		var wall := Build.box(self, Vector3(3.6, 3.0, 0.5), Vector3(cos(a) * (PLAZA_RADIUS - 0.3), 1.5, sin(a) * (PLAZA_RADIUS - 0.3)), Color("#ffffff"))
		wall.rotation.y = -a + PI / 2.0
		wall.get_child(0).visible = false   # 壁の見た目は消して、柵だけ見せる
		var fence := BoxMesh.new()
		fence.size = Vector3(3.4, 0.5, 0.25)
		Build.deco(wall, fence, Build.mat(Color("#c9a27e")), Vector3(0, -1.2, 0))

	# ゲームの入り口(ポータル)
	var games: Array = get_node("/root/Main").GAMES
	for i in games.size():
		var g: Dictionary = games[i]
		var a := TAU * i / games.size() - PI / 2.0
		var pos := Vector3(cos(a) * PORTAL_RADIUS, 0, sin(a) * PORTAL_RADIUS)
		_build_portal(g, pos, a)


## ポータル(光る輪+台+看板)を1つ作る
func _build_portal(g: Dictionary, pos: Vector3, angle: float) -> void:
	var color: Color = g["color"]
	var base := CylinderMesh.new()
	base.top_radius = 2.4
	base.bottom_radius = 2.6
	base.height = 0.25
	Build.deco(self, base, Build.mat(color.darkened(0.2), 0.4), pos + Vector3(0, 0.12, 0))
	var glow := CylinderMesh.new()
	glow.top_radius = 2.0
	glow.bottom_radius = 2.0
	glow.height = 0.05
	Build.deco(self, glow, Build.mat(color, 0.2, 0.0, 2.5), pos + Vector3(0, 0.27, 0))

	var ring := TorusMesh.new()
	ring.inner_radius = 2.0
	ring.outer_radius = 2.35
	ring.rings = 48
	var ring_node := Build.deco(self, ring, Build.mat(color, 0.2, 0.3, 1.8), pos + Vector3(0, 2.5, 0))
	ring_node.rotation = Vector3(PI / 2.0, -angle + PI / 2.0, 0)

	var light := OmniLight3D.new()
	light.position = pos + Vector3(0, 1.5, 0)
	light.light_color = color
	light.light_energy = 2.0
	light.omni_range = 6.0
	add_child(light)

	Build.text3d(self, "%s  [%s]" % [g["title"], g["mode"]], pos + Vector3(0, 5.6, 0), 80, color.lightened(0.35))
	Build.text3d(self, g["text"], pos + Vector3(0, 4.6, 0), 40, Color.WHITE)
	_portals.append({"id": g["id"], "pos": pos, "ring": ring_node, "title": g["title"]})


## スタート位置: 噴水のまわりに輪になって並ぶ
func spawn_point(index: int) -> Vector3:
	var a := index * 0.9
	return Vector3(cos(a) * 6.0, 1.0, sin(a) * 6.0)


## 毎フレーム: ポータルを回し、自分がポータルに入ったか調べる
func game_process(delta: float) -> void:
	_time += delta
	for p in _portals:
		p["ring"].rotate_object_local(Vector3.UP, delta * 0.8)
		p["ring"].position.y = 2.5 + sin(_time * 2.0) * 0.15
	if not _live:
		return
	var me: Node = players.get(local_key)
	var near := ""
	if me:
		for p in _portals:
			if me.global_position.distance_to(p["pos"]) < 2.0:
				near = p["id"]
				if multiplayer.is_server():
					_live = false   # 2回始まらないようにする
					main.start_game(p["id"])
					return
				_hint_label.text = "「%s」ホストがポータルに入るとスタートします" % p["title"]
	if near == "" and _hint_label:
		_hint_label.text = ""


## 落ちても噴水の近くに戻る
func on_player_fell(p: Node) -> void:
	p.teleport(spawn_point(randi() % 8) + Vector3(0, 3, 0))


## プレイヤーが増えた・減ったときに、キャラを足したり消したりする
func sync_players_with_net() -> void:
	if not _live:
		return
	super.sync_players_with_net()
	var ids := Net.players.keys()
	ids.sort()
	for id in ids:
		var k := str(id)
		if not players.has(k):
			var info: Dictionary = Net.players[id]
			spawn_player({"key": k, "auth": id, "name": info["name"], "color": info["color"], "bot": false}, players.size())
	_refresh_player_list()


# ─────────── 広場の画面の文字 ───────────

func _build_hub_ui() -> void:
	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", _panel_style(Color(0.08, 0.09, 0.2, 0.7)))
	panel.position = Vector2(24, 64)
	hud.add_child(panel)
	var box := VBoxContainer.new()
	panel.add_child(box)
	var text := "ひとりで遊んでいます"
	if Net.online:
		if multiplayer.is_server():
			text = "あなたがホストです\nIPアドレス: %s\nポート: %d" % [Net.local_address(), Net.DEFAULT_PORT]
		else:
			text = "部屋に参加中"
	_info_label = make_label(text, 20, Color("#ffd166"))
	box.add_child(_info_label)
	box.add_child(make_label("参加者", 18, Color(1, 1, 1, 0.7)))
	_player_list = VBoxContainer.new()
	box.add_child(_player_list)

	# CPUのつよさはホスト(CPUを動かす人)だけが選べる
	if multiplayer.is_server():
		box.add_child(main.cpu_level_row())

	var leave := Button.new()
	leave.text = "タイトルに戻る"
	leave.focus_mode = Control.FOCUS_NONE
	leave.pressed.connect(func(): main.back_to_title())
	box.add_child(leave)

	_hint_label = make_label("", 28, Color("#ffd166"))
	_hint_label.set_anchors_preset(Control.PRESET_CENTER)
	_hint_label.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_hint_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_hint_label.position.y = 120
	hud.add_child(_hint_label)
	_refresh_player_list()


func _refresh_player_list() -> void:
	if not _player_list:
		return
	for c in _player_list.get_children():
		c.queue_free()
	var ids := Net.players.keys()
	ids.sort()
	for id in ids:
		var p: Dictionary = Net.players[id]
		var mark := " (ホスト)" if id == 1 else ""
		_player_list.add_child(make_label("● %s%s" % [p["name"], mark], 20, p["color"]))


## 広場では点数表は使わない
func refresh_scores() -> void:
	pass
