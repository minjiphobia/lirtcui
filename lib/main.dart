import 'dart:io';
import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:flutter/material.dart';
import 'package:websocket/websocket.dart';
import 'package:web_socket_channel/io.dart';
import 'package:http/http.dart';
import 'package:flutter/services.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  ByteData data = await PlatformAssetBundle().load('assets/ca/cert.pem');
  SecurityContext.defaultContext.setTrustedCertificatesBytes(data.buffer.asUint8List());

  runApp(MyApp());
}

class MyApp extends StatefulWidget {
    @override
    _MyAppState createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> {
    IOWebSocketChannel _channel;
    RTCPeerConnection _peerConnection;
    MediaStream _localStream;
    RTCVideoRenderer _localRenderer = RTCVideoRenderer();
    RTCVideoRenderer _remoteRenderer = RTCVideoRenderer();
    String _id;

    @override
    void initState() {
        super.initState();

        // initialize renderers
        initRenderers();

        _id = generateUUIDV4();

        _publish();
    }

    @override
    Widget build(BuildContext context) {
        return MaterialApp(
            title: 'sfu-ws',
            home: Scaffold(
                appBar: AppBar(
                    title: Text('sfu-ws'),
                ),
                body: OrientationBuilder(builder: (context, orientation) {
                    return Column(
                        children: [
                            Row(
                                children: [
                                    Text('Local Video', style: TextStyle(fontSize: 50.0))
                                ],
                            ),
                            Row(
                                children: [
                                    SizedBox(
                                        width: 160,
                                        height: 120,
                                        child: RTCVideoView(_localRenderer, mirror: true))
                                ],
                            ),
                            Row(
                                children: [
                                    Text('Remote Video', style: TextStyle(fontSize: 50.0))
                                ],
                            ),
                            Row(
                                children: [
                                    SizedBox(
                                        width: 160,
                                        height: 120,
                                        child: RTCVideoView(_remoteRenderer))
                                ],
                            ),
                            ],
                            );
                })));
    }

    initRenderers() async {
        await _localRenderer.initialize();
        await _remoteRenderer.initialize();
    }

    void _getUserMedia() async {
        _localStream = await navigator.mediaDevices.getUserMedia({
            'audio': true,
            'video': true,
        });
        _localRenderer.srcObject = _localStream;
        setState((){});
    }
    String generateUUIDV4() {
        final rnd = Random.secure();
        return '${_format(rnd.nextInt(0x100000000))}-${_format(rnd.nextInt(0x100000000))}-'
                '${_format(rnd.nextInt(0x100000000))}-${_format(rnd.nextInt(0x100000000))}-'
                '${_format(rnd.nextInt(0x100000000))}${_format(rnd.nextInt(0x100000000))}';
    }

    String _format(int value) => value.toRadixString(16).padLeft(8, '0');

    void _publish() async {

        // Connect to WebSocket
        final httpClient = HttpClient()
                ..badCertificateCallback =
                (X509Certificate cert, String host, int port) => true;

        final wsUri = "wss://" + "localhost:10810" + "/ws";

        _channel = await IOWebSocketChannel.connect(
            wsUri
        );

        // Get local media stream
        _getUserMedia();

        // Create a RTCPeerConnection object for sfu mode
       final Map<String, dynamic> offerSdpConstraints = {
            'mandatory': {
                'OfferToReceiveAudio': true,
                'OfferToReceiveVideo': true,
            },
            'optional': [],
        };
        final Map<String, dynamic> _iceServers = {
            'iceServers': [
                {'url': 'stun:stun.l.google.com:19302'},
            ]
        };
        final Map<String, dynamic> _config = {
            'mandatory': {},
            // 'optional': [
            //     {'DtlsSrtpKeyAgreement': true},
            // ],
            'optional': [],
        };

        _peerConnection = await createPeerConnection({
            ..._iceServers,
            ...{'sdpSemantics': 'unified-plan'}
        }, _config);

        // Add local stream to peer connection
        _localStream.getTracks().forEach((track) async {
            _peerConnection.addTrack(track, _localStream);
        });

        // NOTE! set to async
        _peerConnection.onIceCandidate = (candidate) async {
            if (candidate == null) {
                print('---finished onIceCandidate---');
                return;
            }

            // if it sends continusly 
            await Future.delayed(
                const Duration(seconds: 2),
                () => _channel.sink.add(jsonEncode({
                    "method": "trickle",
                    "params": {
                        'candidate': {
                            'sdpMLineIndex': candidate.sdpMLineIndex,
                            'sdpMid': candidate.sdpMid,
                            'candidate': candidate.candidate,
                        },
                    },
                })));
        };

        _peerConnection.onTrack = (event) {
            print('---new track---');
            if (event.track.kind == 'video') {
                setState(() {_remoteRenderer.srcObject = event.streams[0];});
            }
        };

        // Send join message to server
        _sendJoinMessage();

        // Listen for WebSocket messages
        _channel.stream.listen((message) async {
            final data = jsonDecode(message);
            print("---received message---");
            print(data);

            if (data['id'] == _id) {
                // await _handleAnswer(data);
                print('---parsing answer---');
                print(data);
                RTCSessionDescription description = RTCSessionDescription(
                    data['result']['sdp'],
                    data['result']['type'],
                );
                await _peerConnection.setRemoteDescription(description);

                _peerConnection.onRenegotiationNeeded = () async {
                    print('---parsing negotiation---');
                    RTCSessionDescription offer = await _peerConnection.createOffer({});
                    await _peerConnection.setLocalDescription(offer);

                    _channel.sink.add(jsonEncode({
                        'method': 'offer',
                        'params': {
                            'desc': {
                                'type': offer.type,
                                'sdp': offer.sdp,
                            }
                        },
                        'id': _id,
                    }));

                    // Listen for WebSocket messages
                    _channel.stream.listen((message) {
                        final data = jsonDecode(message);

                        if (data['id'] == _id) {
                            print('---parsing answer for renegotiation---');
                            print(data);
                            RTCSessionDescription description = RTCSessionDescription(
                                data['result']['sdp'],
                                data['result']['type'],
                            );
                            _peerConnection.setRemoteDescription(description);
                        }
                    });
                };
            } else if (data['method'] == "trickle") {
                // await _handleTrickle(data['params']);
                print('---parsing tricler---');
                print('---add ice candidate---');
                print(data['params']['candidate']);
                print(data['params']['sdpMid']);
                print(data['params']['sdpMLineIndex']);
                await _peerConnection.addCandidate(
                    RTCIceCandidate(
                        data['params']['candidate'],
                        data['params']['sdpMid'],
                        data['params']['sdpMLineIndex'],
                    ),
                );
            }
        });
    }

    void _sendJoinMessage() async {
        RTCSessionDescription offer = await _peerConnection.createOffer();
        await _peerConnection.setLocalDescription(offer);

        _channel.sink.add(jsonEncode({
            'id': _id,
            'method': 'join',
            'params': {
                'sid': 'test room',
                'offer': {
                    'type': offer.type,
                    'sdp': offer.sdp,
                },
            },
        }));
    }

    void _handleAnswer(Map<String, dynamic> data) async {
        print('---parsing answer---');
        print(data);
        RTCSessionDescription description = RTCSessionDescription(
            data['result']['sdp'],
            data['result']['type'],
        );
        await _peerConnection.setRemoteDescription(description);

        _peerConnection.onRenegotiationNeeded = () async {
            RTCSessionDescription offer = await _peerConnection.createOffer({});
            await _peerConnection.setLocalDescription(offer);

            _channel.sink.add(jsonEncode({
                'method': 'offer',
                'params': {
                    'desc': {
                        'type': offer.type,
                        'sdp': offer.sdp,
                    }
                },
                'id': _id,
            }));

            // Listen for WebSocket messages
            _channel.stream.listen((message) {
                final data = jsonDecode(message);

                if (data['id'] == _id) {
                    print('---parsing answer---');
                    print(data);
                    RTCSessionDescription description = RTCSessionDescription(
                        data['result']['sdp'],
                        data['result']['type'],
                    );
                    _peerConnection.setRemoteDescription(description);
                }
            });
        };
    }

    void _handleTrickle(Map<String, dynamic> params) async {
        print('---parsing tricler---');
        print('---add ice candidate---');
        print(params['candidate']);
        print(params['sdpMid']);
        print(params['sdpMLineIndex']);
        await _peerConnection.addCandidate(
            RTCIceCandidate(
                params['candidate'],
                params['sdpMid'],
                params['sdpMLineIndex'],
            ),
        );
    }

    @override
    void dispose() {
        super.dispose();
        // Close WebSocket connection
        _channel.sink.close();
        _localStream.dispose();
        _localRenderer.dispose();
        _remoteRenderer.dispose();
    }
}
