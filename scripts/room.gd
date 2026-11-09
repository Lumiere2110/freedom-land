extends Node
## ─────────────────────────────────────────────
## Room(ルームとパスワードの係)
## ─────────────────────────────────────────────
## 「ルームを作成」「ルームに参加」で、パソコンやスマホどうしをつなぐ係です。
##
## つなぐ仕組み(WebRTC):
##   WebRTC は、ブラウザでもパソコンでも使える「直接つながる」通信です。
##   ただし、つながる前に「わたしの住所はここです」という紙(SDP と ICE 候補)を
##   おたがいに渡し合う必要があります。この受け渡しを「シグナリング」と呼びます。
##
## 紙の受け渡し(MQTT):
##   紙は、だれでも使える無料の「伝言板」サーバー(MQTT ブローカー)を通して渡します。
##   伝言板には「トピック」という部屋のような名前があり、
##     freedomland/v1/パスワード/host        … ホストあての伝言
##     freedomland/v1/パスワード/g/ゲスト番号 … ゲストあての伝言
##   に書きこみます。同じパスワードを知っている人だけが、同じ場所で出会えます。
##   つながったあとのゲームの通信は、伝言板を通らず直接行います。
##
## MQTT のメッセージ(パケット)は、決まった形のバイト列です。ここでは必要な
## CONNECT(つなぐ)・SUBSCRIBE(伝言を受け取る)・PUBLISH(伝言を書く)・PINGREQ(生きてるよ)
## だけを自分で作っています。

signal room_ready(code: String)     # ホスト: ルームができた
signal failed(message: String)      # うまくいかなかった

const BROKER := "wss://broker.hivemq.com:8884/mqtt"
const TOPIC := "freedomland/v1/"
## STUN サーバー: 「外から見た自分の住所」を教えてくれる無料のサーバー
const ICE := {"iceServers": [{"urls": ["stun:stun.l.google.com:19302", "stun:stun1.l.google.com:19302"]}]}
## パスワードに使う文字(0とO、1とIなど、まちがえやすい文字は入れない)
const CODE_CHARS := "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"
const JOIN_TIMEOUT := 25.0

var is_host := false
var code := ""
var peer: WebRTCMultiplayerPeer
var my_peer_id := 1

var _ws := WebSocketPeer.new()
var _buffer := PackedByteArray()
var _sent_connect := false
var _mqtt_ready := false
var _ping := 0.0
var _wait := 0.0              # ゲスト: つながるまでの待ち時間
var _active := false
var _conns := {}              # ホスト: ゲスト番号 → WebRTCPeerConnection
var _conn: WebRTCPeerConnection   # ゲスト: ホストとのつながり


## パスワードを作る(6文字)
static func make_code() -> String:
	var s := ""
	for i in 6:
		s += CODE_CHARS[randi() % CODE_CHARS.length()]
	return s


## ホストとしてルームを作る
func start_host() -> WebRTCMultiplayerPeer:
	is_host = true
	code = make_code()
	my_peer_id = 1
	peer = WebRTCMultiplayerPeer.new()
	peer.create_server()
	_open_broker()
	return peer


## ゲストとしてルームに入る
func start_guest(room_code: String) -> WebRTCMultiplayerPeer:
	is_host = false
	code = room_code.strip_edges().to_upper()
	my_peer_id = randi_range(2, 1 << 30)
	peer = WebRTCMultiplayerPeer.new()
	peer.create_client(my_peer_id)
	_conn = _new_connection(1)
	peer.add_peer(_conn, 1)   # ホストはいつも 1 番
	_wait = 0.0
	_open_broker()
	return peer


## やめる(タイトルに戻るとき)
func stop() -> void:
	_active = false
	_mqtt_ready = false
	if _ws.get_ready_state() != WebSocketPeer.STATE_CLOSED:
		_ws.close()
	_conns.clear()
	_conn = null


func _open_broker() -> void:
	_ws = WebSocketPeer.new()
	_ws.supported_protocols = PackedStringArray(["mqtt"])
	_buffer.clear()
	_sent_connect = false
	_mqtt_ready = false
	_active = true
	var err := _ws.connect_to_url(BROKER)
	if err != OK:
		_fail("伝言板サーバーにつながりませんでした。インターネットを確かめてください。")


func _fail(message: String) -> void:
	if not _active:
		return
	stop()
	failed.emit(message)


# ─────────── 毎フレーム ───────────

func _process(delta: float) -> void:
	if not _active:
		return
	_ws.poll()
	var st := _ws.get_ready_state()
	if st == WebSocketPeer.STATE_OPEN:
		if not _sent_connect:
			_sent_connect = true
			_ws.send(_packet(0x10, _str("MQTT") + PackedByteArray([4, 2, 0, 60]) + _str("fl%d" % randi())))
		while _ws.get_available_packet_count() > 0:
			_buffer.append_array(_ws.get_packet())
		_read_packets()
		# 生きてるよ(30秒ごと)
		_ping += delta
		if _ping > 30.0:
			_ping = 0.0
			_ws.send(PackedByteArray([0xC0, 0]))
	elif st == WebSocketPeer.STATE_CLOSED:
		if is_host and _mqtt_ready:
			# ホスト: 伝言板につなぎ直す(あとから来る人も入れるように)
			_open_broker()
		else:
			_fail("伝言板サーバーにつながりませんでした。インターネットを確かめてください。")
		return
	# ゲスト: なかなかつながらないとき
	if not is_host:
		_wait += delta
		if peer.get_connection_status() == MultiplayerPeer.CONNECTION_CONNECTED:
			_ws.close()
			_active = false
		elif _wait > JOIN_TIMEOUT:
			_fail("ルーム「%s」が見つかりませんでした。パスワードを確かめてください。" % code)


## たまったバイト列から MQTT のパケットを1つずつ取り出す
func _read_packets() -> void:
	while _buffer.size() >= 2:
		# 残りの長さ(1〜4バイトの可変長)
		var length := 0
		var mult := 1
		var i := 1
		var complete := false
		while i < _buffer.size() and i <= 4:
			var d: int = _buffer[i]
			length += (d & 127) * mult
			mult *= 128
			i += 1
			if d & 128 == 0:
				complete = true
				break
		if not complete or _buffer.size() < i + length:
			return   # まだ全部届いていない
		var kind: int = _buffer[0] >> 4
		var body := _buffer.slice(i, i + length)
		_buffer = _buffer.slice(i + length)
		match kind:
			2:   # CONNACK: つながった → 伝言を受け取る場所を登録
				var topic := TOPIC + code + ("/host" if is_host else "/g/%d" % my_peer_id)
				_ws.send(_packet(0x82, PackedByteArray([0, 1]) + _str(topic) + PackedByteArray([0])))
			9:   # SUBACK: 登録できた
				if not _mqtt_ready:
					_mqtt_ready = true
					if is_host:
						room_ready.emit(code)
					else:
						_conn.create_offer()   # ホストに「つながりたい」の紙を作る
			3:   # PUBLISH: 伝言が届いた
				var tlen: int = (body[0] << 8) | body[1]
				var text := body.slice(2 + tlen).get_string_from_utf8()
				var data = JSON.parse_string(text)
				if data is Dictionary:
					_on_message(data)


## 伝言を書く
func _publish(topic: String, data: Dictionary) -> void:
	if _ws.get_ready_state() == WebSocketPeer.STATE_OPEN:
		_ws.send(_packet(0x30, _str(TOPIC + code + topic) + JSON.stringify(data).to_utf8_buffer()))


# ─────────── WebRTC ───────────

func _new_connection(other_id: int) -> WebRTCPeerConnection:
	var c := WebRTCPeerConnection.new()
	c.initialize(ICE)
	# 自分の「住所の紙」ができたら、相手に送る
	c.session_description_created.connect(func(type: String, sdp: String):
		c.set_local_description(type, sdp)
		_send_to(other_id, {"kind": type, "sdp": sdp}))
	c.ice_candidate_created.connect(func(mid: String, index: int, cand: String):
		_send_to(other_id, {"kind": "candidate", "mid": mid, "index": index, "cand": cand}))
	return c


## 相手に伝言を送る(ホストへは /host、ゲストへは /g/番号)
func _send_to(other_id: int, data: Dictionary) -> void:
	data["from"] = my_peer_id
	if is_host:
		_publish("/g/%d" % other_id, data)
	else:
		_publish("/host", data)


## 伝言が届いたとき
func _on_message(d: Dictionary) -> void:
	var from := int(d.get("from", 0))
	var kind: String = d.get("kind", "")
	if is_host:
		if kind == "offer" and not _conns.has(from) and from > 1:
			if _conns.size() >= Net.MAX_CLIENTS:
				return
			var c := _new_connection(from)
			_conns[from] = c
			peer.add_peer(c, from)
			c.set_remote_description("offer", d["sdp"])   # → 自動で answer が作られる
		elif kind == "candidate" and _conns.has(from):
			_conns[from].add_ice_candidate(d["mid"], int(d["index"]), d["cand"])
	else:
		if kind == "answer" and _conn:
			_conn.set_remote_description("answer", d["sdp"])
		elif kind == "candidate" and _conn:
			_conn.add_ice_candidate(d["mid"], int(d["index"]), d["cand"])


# ─────────── MQTT のバイト列づくり ───────────

## 文字列 = 長さ(2バイト) + 中身
func _str(s: String) -> PackedByteArray:
	var b := s.to_utf8_buffer()
	return PackedByteArray([b.size() >> 8, b.size() & 255]) + b


## パケット = 種類(1バイト) + 残りの長さ(可変長) + 中身
func _packet(header: int, body: PackedByteArray) -> PackedByteArray:
	var out := PackedByteArray([header])
	var n := body.size()
	while true:
		var d := n % 128
		n = n / 128
		if n > 0:
			d |= 128
		out.append(d)
		if n == 0:
			break
	return out + body
