extends RefCounted
## ─────────────────────────────────────────────
## Build(ものづくり係)
## ─────────────────────────────────────────────
## 床・壁・木・文字などの「3Dのもの」をプログラムで作るための便利関数集です。
## 画像やモデルのファイルを使わず、四角(Box)・円柱(Cylinder)・球(Sphere)などの
## 基本の形を組み合わせて、すべての見た目を作っています。
##
## 使い方:  const Build = preload("res://scripts/build.gd")
##          Build.box(親ノード, 大きさ, 位置, 色)
##
## 「static func」は、Build.〇〇() とそのまま呼べる関数という意味です。


## 色や質感(ザラザラ・ツルツル・光る)を決める「マテリアル」を作る
## rough = ざらざら具合(0=ピカピカ, 1=ざらざら)
## glow  = 0より大きいと、その強さで自分から光る
static func mat(color: Color, rough := 0.8, metal := 0.0, glow := 0.0) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = color
	m.roughness = rough
	m.metallic = metal
	if glow > 0.0:
		m.emission_enabled = true
		m.emission = color
		m.emission_energy_multiplier = glow
	if color.a < 1.0:
		m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	return m


## 形(メッシュ)を置くだけ。当たり判定はつかない(飾り用)
static func deco(parent: Node, mesh: Mesh, material: Material, pos: Vector3, rot := Vector3.ZERO) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.material_override = material
	mi.position = pos
	mi.rotation = rot
	parent.add_child(mi)
	return mi


## 乗れる箱(当たり判定つき)を作る
static func box(parent: Node, size: Vector3, pos: Vector3, color: Color, rough := 0.8) -> StaticBody3D:
	var body := StaticBody3D.new()
	body.position = pos
	parent.add_child(body)
	var bm := BoxMesh.new()
	bm.size = size
	deco(body, bm, mat(color, rough), Vector3.ZERO)
	var shape := BoxShape3D.new()
	shape.size = size
	var cs := CollisionShape3D.new()
	cs.shape = shape
	body.add_child(cs)
	return body


## 乗れる円柱(当たり判定つき)を作る。丸い床や柱に使う
static func cylinder(parent: Node, radius: float, height: float, pos: Vector3, color: Color, sides := 48) -> StaticBody3D:
	var body := StaticBody3D.new()
	body.position = pos
	parent.add_child(body)
	var cm := CylinderMesh.new()
	cm.top_radius = radius
	cm.bottom_radius = radius
	cm.height = height
	cm.radial_segments = sides
	deco(body, cm, mat(color), Vector3.ZERO)
	var shape := CylinderShape3D.new()
	shape.radius = radius
	shape.height = height
	var cs := CollisionShape3D.new()
	cs.shape = shape
	body.add_child(cs)
	return body


## 空中に浮かぶ文字(いつもカメラのほうを向く)
static func text3d(parent: Node, text: String, pos: Vector3, size := 64, color := Color.WHITE) -> Label3D:
	var l := Label3D.new()
	l.text = text
	l.position = pos
	l.font = Net.font
	l.font_size = size
	l.outline_size = int(size / 4.0)
	l.outline_modulate = Color(0, 0, 0, 0.75)
	l.modulate = color
	l.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	l.pixel_size = 0.01
	parent.add_child(l)
	return l


## 空・光・影などの「世界の雰囲気」を作る
## top = 空の上のほうの色, horizon = 地平線の色, sun_dir = 太陽の向き(度)
static func environment(parent: Node, top: Color, horizon: Color, ground: Color, sun_energy := 1.2, sun_angle := Vector3(-50, 35, 0)) -> void:
	var sky_mat := ProceduralSkyMaterial.new()
	sky_mat.sky_top_color = top
	sky_mat.sky_horizon_color = horizon
	sky_mat.ground_bottom_color = ground
	sky_mat.ground_horizon_color = horizon
	var sky := Sky.new()
	sky.sky_material = sky_mat

	var env := Environment.new()
	env.background_mode = Environment.BG_SKY
	env.sky = sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.ambient_light_energy = 0.9
	env.tonemap_mode = Environment.TONE_MAPPER_ACES   # 色をきれいにまとめる
	env.glow_enabled = true                            # 光るものがふわっと光る
	env.glow_intensity = 0.6
	env.ssao_enabled = true                            # すみっこに自然な影をつける
	env.fog_enabled = true                             # 遠くをかすませる
	env.fog_light_color = horizon
	env.fog_density = 0.004

	var we := WorldEnvironment.new()
	we.environment = env
	parent.add_child(we)

	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = sun_angle
	sun.light_energy = sun_energy
	sun.shadow_enabled = true
	sun.directional_shadow_max_distance = 80.0
	parent.add_child(sun)


## 木を1本立てる(幹=円柱、葉=円すい2段)
static func tree(parent: Node, pos: Vector3, s := 1.0) -> void:
	var trunk := CylinderMesh.new()
	trunk.top_radius = 0.25 * s
	trunk.bottom_radius = 0.35 * s
	trunk.height = 1.6 * s
	deco(parent, trunk, mat(Color("#8a5a3c")), pos + Vector3(0, 0.8 * s, 0))
	var leaf_color := Color("#3fbf6f").lerp(Color("#2a9d8f"), randf())
	for i in 2:
		var cone := CylinderMesh.new()
		cone.top_radius = 0.0
		cone.bottom_radius = (1.5 - i * 0.4) * s
		cone.height = 1.8 * s
		deco(parent, cone, mat(leaf_color), pos + Vector3(0, (2.2 + i * 1.0) * s, 0))


## 街灯(てっぺんが光る柱)
static func lamp(parent: Node, pos: Vector3, color := Color("#ffe8a3")) -> void:
	var pole := CylinderMesh.new()
	pole.top_radius = 0.08
	pole.bottom_radius = 0.12
	pole.height = 3.2
	deco(parent, pole, mat(Color("#3d405b"), 0.4, 0.6), pos + Vector3(0, 1.6, 0))
	var bulb := SphereMesh.new()
	bulb.radius = 0.3
	bulb.height = 0.6
	deco(parent, bulb, mat(color, 0.2, 0.0, 3.0), pos + Vector3(0, 3.35, 0))
	var light := OmniLight3D.new()
	light.position = pos + Vector3(0, 3.3, 0)
	light.light_color = color
	light.light_energy = 1.4
	light.omni_range = 7.0
	parent.add_child(light)


## 回るコインのような丸い板(ゲームのアイテム用)
static func coin_mesh(radius := 0.5) -> CylinderMesh:
	var c := CylinderMesh.new()
	c.top_radius = radius
	c.bottom_radius = radius
	c.height = 0.12
	c.radial_segments = 24
	return c
