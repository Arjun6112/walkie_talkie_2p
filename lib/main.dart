import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:shared_preferences/shared_preferences.dart';

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

class WalkieTalkiePageState extends State<WalkieTalkiePage>
    with SingleTickerProviderStateMixin {
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
  late List<double> barHeights;
  late AnimationController _animationController;
  final int numberOfBars = 12;
  List<RTCIceCandidate> _pendingCandidates = [];
  bool _offerSet = false;

  @override
  void initState() {
    super.initState();
    // Initialize bar heights
    barHeights = List.generate(numberOfBars, (index) => 0.3);

    // Setup animation controller
    _animationController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 600),
    );
    _animationController.repeat(reverse: true);

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
              _updateVisualizerBars();
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
      // Create peer connection first
      peerConnection = await createPeerConnection({
        'iceServers': [
          {
            'urls': [
              'stun:stun.l.google.com:19302',
              'stun:stun1.l.google.com:19302',
            ]
          }
        ],
        'sdpSemantics': 'unified-plan',
        'iceTransportPolicy': 'all',
      });

      // Get audio stream
      localStream = await navigator.mediaDevices.getUserMedia({
        'audio': {
          'echoCancellation': true,
          'noiseSuppression': true,
          'autoGainControl': true,
        },
        'video': false
      });

      // Add tracks to peer connection
      localStream!.getTracks().forEach((track) {
        peerConnection!.addTrack(track, localStream!);
      });

      // Handle connection state changes with more detailed logging
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
              _handleConnectionFailure();
              break;
            case RTCPeerConnectionState.RTCPeerConnectionStateDisconnected:
              connectionStatus = 'Disconnected - Trying to reconnect...';
              isConnected = false;
              break;
            default:
              connectionStatus = 'Connection state: $state';
          }
        });
      };

      // Improved ICE candidate handling
      peerConnection!.onIceCandidate = (candidate) {
        print('Generated ICE candidate: ${candidate.candidate}');
        if (candidate.candidate != null) {
          if (_offerSet) {
            _sharePeerInfo('ice', {'candidate': candidate.toMap()});
          } else {
            _pendingCandidates.add(candidate);
          }
        }
      };

      // Handle ICE connection state
      peerConnection!.onIceConnectionState = (RTCIceConnectionState state) {
        print('ICE Connection State: $state');
        if (state == RTCIceConnectionState.RTCIceConnectionStateConnected) {
          setState(() {
            isConnected = true;
            connectionStatus = 'Connected';
          });
        }
      };

      // Start the offer/answer process
      await _checkAndCreateOffer();
    } catch (e) {
      print('WebRTC initialization error: $e');
      setState(() {
        connectionStatus = 'Error: $e';
      });
    }
  }

  void _handleConnectionFailure() async {
    print('Connection failed - attempting recovery');
    setState(() {
      connectionStatus = 'Connection failed - attempting recovery...';
      isConnected = false;
    });

    try {
      await peerConnection?.close();
      await _initWebRTC();
    } catch (e) {
      print('Recovery failed: $e');
      setState(() {
        connectionStatus = 'Recovery failed. Please reset manually.';
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

        final offer = await peerConnection!.createOffer();
        print('Created offer: ${offer.sdp}');

        await peerConnection!.setLocalDescription(offer);
        _offerSet = true;

        // Share pending candidates
        for (var candidate in _pendingCandidates) {
          await _sharePeerInfo('ice', {'candidate': candidate.toMap()});
        }
        _pendingCandidates.clear();

        await _sharePeerInfo('offer', {
          'sdp': offer.sdp,
          'type': offer.type,
          'timestamp': DateTime.now().millisecondsSinceEpoch,
        });
      } else {
        setState(() {
          connectionStatus = 'Processing existing offer...';
        });

        final offerData = jsonDecode(existingOffer);
        print('Processing offer: ${offerData['sdp']}');

        await peerConnection!.setRemoteDescription(
          RTCSessionDescription(offerData['sdp'], offerData['type']),
        );
        _offerSet = true;

        final answer = await peerConnection!.createAnswer();
        await peerConnection!.setLocalDescription(answer);

        // Share pending candidates
        for (var candidate in _pendingCandidates) {
          await _sharePeerInfo('ice', {'candidate': candidate.toMap()});
        }
        _pendingCandidates.clear();

        await _sharePeerInfo('answer', {
          'sdp': answer.sdp,
          'type': answer.type,
          'timestamp': DateTime.now().millisecondsSinceEpoch,
        });

        // Immediately check for ICE candidates after processing offer
        await _checkForIceCandidates();
      }
    } catch (e) {
      print('Offer/Answer error: $e');
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
      try {
        final data = jsonDecode(candidateJson);
        if (data['type'] == 'ice') {
          print('Adding ICE candidate: ${data['candidate']['candidate']}');
          await peerConnection!.addCandidate(
            RTCIceCandidate(
              data['candidate']['candidate'],
              data['candidate']['sdpMid'],
              data['candidate']['sdpMLineIndex'],
            ),
          );
        }
      } catch (e) {
        print('Error adding ICE candidate: $e');
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

  void _updateVisualizerBars() {
    if (!isRemoteAudioActive) {
      setState(() {
        barHeights = List.generate(numberOfBars, (index) => 0.3);
      });
      return;
    }

    setState(() {
      barHeights = List.generate(numberOfBars, (index) {
        return 0.3 + Random().nextDouble() * 0.7;
      });
    });
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
            // New audio visualizer
            Container(
              height: 120,
              width: 300,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              decoration: BoxDecoration(
                color: Colors.grey[100],
                borderRadius: BorderRadius.circular(16),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withOpacity(0.1),
                    blurRadius: 10,
                    spreadRadius: 1,
                  ),
                ],
              ),
              child: AnimatedBuilder(
                animation: _animationController,
                builder: (context, child) {
                  return Row(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    children: List.generate(
                      numberOfBars,
                      (index) => AnimatedContainer(
                        duration: const Duration(milliseconds: 200),
                        width: 12,
                        height: 80 * barHeights[index],
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(20),
                          gradient: LinearGradient(
                            begin: Alignment.bottomCenter,
                            end: Alignment.topCenter,
                            colors: isRemoteAudioActive
                                ? [
                                    Colors.blue[300]!,
                                    Colors.blue[400]!,
                                    Colors.blue[600]!,
                                  ]
                                : [
                                    Colors.grey[300]!,
                                    Colors.grey[400]!,
                                    Colors.grey[500]!,
                                  ],
                          ),
                        ),
                      ),
                    ),
                  );
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
    _animationController.dispose();
    _connectionTimer?.cancel();
    audioLevelTimer?.cancel();
    localStream?.dispose();
    remoteStream?.dispose();
    peerConnection?.dispose();
    _remoteRenderer.dispose();
    super.dispose();
  }
}
