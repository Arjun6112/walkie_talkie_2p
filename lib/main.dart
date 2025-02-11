import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:convert';

void main() {
  runApp(const WalkieTalkieApp());
}

class WalkieTalkieApp extends StatelessWidget {
  const WalkieTalkieApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Walkie Talkie',
      theme: ThemeData(primarySwatch: Colors.blue),
      home: const WalkieTalkiePage(),
    );
  }
}

class WalkieTalkiePage extends StatefulWidget {
  const WalkieTalkiePage({super.key});

  @override
  WalkieTalkiePageState createState() => WalkieTalkiePageState();
}

class WalkieTalkiePageState extends State<WalkieTalkiePage> {
  RTCPeerConnection? peerConnection;
  MediaStream? localStream;
  MediaStream? remoteStream;
  final _remoteRenderer = RTCVideoRenderer();
  bool isMuted = false;
  bool isConnected = false;
  String connectionStatus = 'Initializing...';
  bool isRemoteAudioActive = false;
  Timer? audioLevelTimer;
  List<MediaDeviceInfo> _audioOutputDevices = [];
  String? _selectedAudioOutput;
  Timer? _connectionTimer;

  @override
  void initState() {
    super.initState();
    _initRenderers();
    _initAudioDevices();
  }

  Future<void> _initAudioDevices() async {
    try {
      final devices = await navigator.mediaDevices.enumerateDevices();
      setState(() {
        _audioOutputDevices =
            devices.where((device) => device.kind == 'audiooutput').toList();
        if (_audioOutputDevices.isNotEmpty) {
          _selectedAudioOutput = _audioOutputDevices.first.deviceId;
        }
      });
    } catch (e) {
      print('Error getting audio devices: $e');
    }
  }

  Future<void> _setAudioOutput(String deviceId) async {
    try {
      await _remoteRenderer.audioOutput(deviceId);
      setState(() {
        _selectedAudioOutput = deviceId;
      });
    } catch (e) {
      print('Error setting audio output: $e');
    }
  }

  void _startAudioLevelMonitoring(MediaStream stream) {
    audioLevelTimer?.cancel();
    audioLevelTimer =
        Timer.periodic(const Duration(milliseconds: 100), (timer) async {
      if (stream.getAudioTracks().isEmpty) return;

      final audioTrack = stream.getAudioTracks().first;
      // Get audio levels through WebRTC stats
      try {
        final stats = await peerConnection!.getStats(audioTrack);
        stats.forEach((stat) {
          if (stat.type == 'inbound-rtp' && stat.values['audioLevel'] != null) {
            final audioLevel = stat.values['audioLevel'] as double;
            setState(() {
              isRemoteAudioActive =
                  audioLevel > 0.01; // Adjust threshold as needed
            });
          }
        });
      } catch (e) {
        print('Error getting audio levels: $e');
      }
    });
  }

  Future<void> _initRenderers() async {
    await _remoteRenderer.initialize();
    _initWebRTC();
  }

  Future<void> _initWebRTC() async {
    setState(() {
      connectionStatus = 'Getting user media...';
    });

    try {
      // Get audio stream with specific constraints
      localStream = await navigator.mediaDevices.getUserMedia({
        'audio': {
          'echoCancellation': true,
          'noiseSuppression': true,
          'autoGainControl': true
        },
        'video': false
      });

      setState(() {
        connectionStatus = 'Creating peer connection...';
      });

      // Create peer connection with specific configuration
      peerConnection = await createPeerConnection({
        'iceServers': [
          {
            'urls': [
              'stun:stun1.l.google.com:19302',
              'stun:stun2.l.google.com:19302'
            ]
          }
        ],
        'sdpSemantics': 'unified-plan',
        'mandatory': {
          'OfferToReceiveAudio': true,
          'OfferToReceiveVideo': false
        },
      });

      // Add connection timeout
      _connectionTimer?.cancel();
      _connectionTimer = Timer(const Duration(seconds: 30), () {
        if (!isConnected) {
          setState(() {
            connectionStatus = 'Connection timeout. Please try again.';
          });
        }
      });

      // Add local stream tracks to peer connection
      localStream!.getTracks().forEach((track) {
        peerConnection!.addTrack(track, localStream!);
      });

      // Handle connection state changes
      peerConnection!.onConnectionState = (RTCPeerConnectionState state) {
        print('Connection state changed to: $state');
        setState(() {
          switch (state) {
            case RTCPeerConnectionState.RTCPeerConnectionStateConnected:
              connectionStatus = 'Connected';
              isConnected = true;
              _connectionTimer?.cancel();
              break;
            case RTCPeerConnectionState.RTCPeerConnectionStateFailed:
              connectionStatus =
                  'Connection failed. Please reset and try again.';
              isConnected = false;
              break;
            case RTCPeerConnectionState.RTCPeerConnectionStateDisconnected:
              connectionStatus = 'Disconnected';
              isConnected = false;
              break;
            default:
              connectionStatus = 'Connection state: $state';
          }
        });
      };

      // Handle ICE connection state changes
      peerConnection!.onIceConnectionState = (RTCIceConnectionState state) {
        print('ICE state changed to: $state');
        setState(() {
          switch (state) {
            case RTCIceConnectionState.RTCIceConnectionStateConnected:
              connectionStatus = 'ICE Connected';
              break;
            case RTCIceConnectionState.RTCIceConnectionStateFailed:
              connectionStatus = 'ICE Connection failed. Try resetting.';
              break;
            default:
              // Don't update status for other ICE states to avoid confusion
              break;
          }
        });
      };

      // Handle ICE candidates
      peerConnection!.onIceCandidate = (candidate) {
        if (candidate.candidate != null) {
          _sharePeerInfo('ice', {
            'candidate': candidate.toMap(),
          });
        }
      };

      // Handle remote stream
      peerConnection!.onTrack = (RTCTrackEvent event) {
        if (event.streams.isNotEmpty) {
          print('Received remote track: ${event.track.kind}');

          if (event.track.kind == 'audio') {
            print('Audio track received. Enabled: ${event.track.enabled}');
            event.track.onEnded = () {
              print('Audio track ended');
            };
            event.track.onMute = () {
              print('Audio track muted');
            };
            event.track.onUnMute = () {
              print('Audio track unmuted');
            };
          }

          setState(() {
            remoteStream = event.streams[0];
            _remoteRenderer.srcObject = remoteStream;
            isConnected = true;
            connectionStatus = 'Remote stream received';
          });

          // Start monitoring audio levels
          _startAudioLevelMonitoring(event.streams[0]);
        }
      };

      // Start the offer/answer process
      _checkAndCreateOffer();
    } catch (e) {
      setState(() {
        connectionStatus = 'Error: $e';
      });
    }
  }

  Future<void> _checkAndCreateOffer() async {
    final prefs = await SharedPreferences.getInstance();
    final existingOffer = prefs.getString('room_offer');

    try {
      if (existingOffer == null) {
        setState(() {
          connectionStatus = 'Creating offer...';
        });

        // Create offer with specific constraints
        final offer = await peerConnection!.createOffer(
            {'offerToReceiveAudio': true, 'offerToReceiveVideo': false});

        await peerConnection!.setLocalDescription(offer);

        await _sharePeerInfo('offer', {
          'sdp': offer.sdp,
          'type': offer.type,
        });

        setState(() {
          connectionStatus = 'Offer created and shared';
        });
      } else {
        setState(() {
          connectionStatus = 'Processing existing offer...';
        });

        final offerData = jsonDecode(existingOffer);
        await peerConnection!.setRemoteDescription(
          RTCSessionDescription(offerData['sdp'], offerData['type']),
        );

        final answer = await peerConnection!.createAnswer(
            {'offerToReceiveAudio': true, 'offerToReceiveVideo': false});

        await peerConnection!.setLocalDescription(answer);

        await _sharePeerInfo('answer', {
          'sdp': answer.sdp,
          'type': answer.type,
        });

        setState(() {
          connectionStatus = 'Answer created and shared';
        });
      }
    } catch (e) {
      setState(() {
        connectionStatus = 'Error in offer/answer: $e';
      });
    }
  }

  Future<void> _sharePeerInfo(String type, Map<String, dynamic> data) async {
    final prefs = await SharedPreferences.getInstance();
    final peerInfo = {
      'type': type,
      ...data,
    };

    if (type == 'offer') {
      await prefs.setString('room_offer', jsonEncode(peerInfo));
    } else if (type == 'answer') {
      await prefs.setString('room_answer', jsonEncode(peerInfo));
      _checkForIceCandidates();
    } else if (type == 'ice') {
      final candidates = prefs.getStringList('ice_candidates') ?? [];
      candidates.add(jsonEncode(peerInfo));
      await prefs.setStringList('ice_candidates', candidates);
    }
  }

  Future<void> _checkForIceCandidates() async {
    final prefs = await SharedPreferences.getInstance();
    final candidates = prefs.getStringList('ice_candidates') ?? [];

    for (final candidateJson in candidates) {
      final data = jsonDecode(candidateJson);
      if (data['type'] == 'ice') {
        await peerConnection!.addCandidate(
          RTCIceCandidate(
            data['candidate']['candidate'],
            data['candidate']['sdpMid'],
            data['candidate']['sdpMLineIndex'],
          ),
        );
      }
    }
  }

  void _toggleMute() {
    setState(() {
      isMuted = !isMuted;
      localStream?.getAudioTracks().forEach((track) {
        track.enabled = !isMuted;
      });
    });
  }

  Future<void> _resetConnection() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.clear();

    // Clean up existing connections
    _connectionTimer?.cancel();
    localStream?.dispose();
    remoteStream?.dispose();
    await peerConnection?.close();

    setState(() {
      isConnected = false;
      connectionStatus = 'Resetting connection...';
    });

    // Reinitialize WebRTC
    await _initWebRTC();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Walkie Talkie')),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(
              connectionStatus,
              style: Theme.of(context).textTheme.titleMedium,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 20),
            // Add the AudioWave widget through HtmlElementView
            SizedBox(
              height: 100,
              child: HtmlElementView(
                viewType: 'audio-wave',
                onPlatformViewCreated: (int id) {
                  // Initialize the audio wave component
                  // The JavaScript side will handle the actual rendering
                },
              ),
            ),
            const SizedBox(height: 20),
            Text(
              isMuted ? 'Voice Muted' : 'Voice Active',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 20),
            FloatingActionButton(
              onPressed: _toggleMute,
              child: Icon(isMuted ? Icons.mic_off : Icons.mic),
            ),
            const SizedBox(height: 20),
            ElevatedButton(
              onPressed: _resetConnection,
              child: const Text('Reset Connection'),
            ),
            if (_audioOutputDevices.isNotEmpty) ...[
              const SizedBox(height: 20),
              DropdownButton<String>(
                value: _selectedAudioOutput,
                items: _audioOutputDevices.map((device) {
                  return DropdownMenuItem(
                    value: device.deviceId,
                    child: Text(device.label),
                  );
                }).toList(),
                onChanged: (String? deviceId) {
                  if (deviceId != null) {
                    _setAudioOutput(deviceId);
                  }
                },
              ),
            ],
            const SizedBox(height: 20),
            Text(
              'Remote Audio Status: ${isRemoteAudioActive ? "Active" : "Silent"}',
              style: Theme.of(context).textTheme.bodyLarge,
            ),
          ],
        ),
      ),
    );
  }

  @override
  void dispose() {
    _connectionTimer?.cancel();
    audioLevelTimer?.cancel();
    localStream?.dispose();
    remoteStream?.dispose();
    peerConnection?.dispose();
    _remoteRenderer.dispose();
    super.dispose();
  }
}
