import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter_image_compress/flutter_image_compress.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:geolocator/geolocator.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:http/http.dart' as http;

void main() => runApp(MyApp());

class MyApp extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'PhotoSync',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark(useMaterial3: true).copyWith(
        scaffoldBackgroundColor: Color(0xFF0A0A0A),
        primaryColor: Color(0xFF2A2A2A),
        colorScheme: ColorScheme.dark(
          primary: Color(0xFF2A2A2A),
          secondary: Color(0xFF404040),
          surface: Color(0xFF1A1A1A),
        ),
      ),
      home: PhotoHomePage(),
    );
  }
}

class PhotoHomePage extends StatefulWidget {
  @override
  _PhotoHomePageState createState() => _PhotoHomePageState();
}

class _PhotoHomePageState extends State<PhotoHomePage> with TickerProviderStateMixin {
  final ImagePicker picker = ImagePicker();

  File? _image;

  DateTime? _timestamp;
  int? _fileSizeBytes;
  int? _width;
  int? _height;

  String _deviceInfo = "";
  String _location = "";

  bool _metadataReady = false;
  bool _isUploading = false;

  late AnimationController _animationController;
  late Animation<double> _fadeAnimation;
  
  // Pulse animation for hint
  late AnimationController _pulseController;
  late Animation<double> _pulseAnimation;

  @override
  void initState() {
    super.initState();
    _animationController = AnimationController(
      duration: Duration(milliseconds: 800),
      vsync: this,
      value: 1.0, // Start at full opacity
    );
    _fadeAnimation = CurvedAnimation(
      parent: _animationController,
      curve: Curves.easeInOut,
    );
    
    // Pulse animation setup
    _pulseController = AnimationController(
      duration: Duration(milliseconds: 2000),
      vsync: this,
    )..repeat(reverse: true);
    
    _pulseAnimation = Tween<double>(begin: 1.0, end: 1.08).animate(
      CurvedAnimation(parent: _pulseController, curve: Curves.easeInOut),
    );
  }

  @override
  void dispose() {
    _animationController.dispose();
    _pulseController.dispose();
    super.dispose();
  }

  // -----------------------------------------------------------
  // 📌 PICK IMAGE
  // -----------------------------------------------------------
  Future<void> pickImage() async {
    final pickedFile = await picker.pickImage(source: ImageSource.camera);

    if (pickedFile == null) return;

    final File file = File(pickedFile.path);

    setState(() => _image = file);
    _pulseController.stop(); // Stop pulse when image is captured

    await _collectMetadata(file);
  }

  // -----------------------------------------------------------
  // 📌 COLLECT METADATA
  // -----------------------------------------------------------
  Future<void> _collectMetadata(File file) async {
    try {
      _timestamp = DateTime.now();

      final bytes = await file.readAsBytes();
      _fileSizeBytes = bytes.length;

      final comp = Completer<ui.Image>();
      ui.decodeImageFromList(bytes, (img) => comp.complete(img));
      final img = await comp.future;

      _width = img.width;
      _height = img.height;

      await _getDeviceInfo();
      await _getLocation();

      if (mounted) {
        setState(() => _metadataReady = true);
      }
    } catch (e) {
      print("Error collecting metadata: $e");
    }
  }

  // -----------------------------------------------------------
  // 📌 DEVICE INFO
  // -----------------------------------------------------------
  Future<void> _getDeviceInfo() async {
    try {
      final info = await DeviceInfoPlugin().androidInfo;
      _deviceInfo = "${info.model}, SDK: ${info.version.sdkInt}";
    } catch (e) {
      _deviceInfo = "Unknown device";
      print("Error getting device info: $e");
    }
  }

  // -----------------------------------------------------------
  // 📌 LOCATION
  // -----------------------------------------------------------
  Future<void> _getLocation() async {
    try {
      bool enabled = await Geolocator.isLocationServiceEnabled();
      if (!enabled) {
        _location = "Location services disabled";
        return;
      }

      LocationPermission perm = await Geolocator.checkPermission();
      if (perm == LocationPermission.denied) {
        perm = await Geolocator.requestPermission();
        if (perm == LocationPermission.denied) {
          _location = "Location permission denied";
          return;
        }
      }

      if (perm == LocationPermission.deniedForever) {
        _location = "Location permission denied permanently";
        return;
      }

      final p = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.high,
      );

      _location = "${p.latitude.toStringAsFixed(6)}, ${p.longitude.toStringAsFixed(6)}";
    } catch (e) {
      _location = "Location unavailable";
      print("Error getting location: $e");
    }
  }

  // -----------------------------------------------------------
  // 📌 UPLOAD IMAGE
  // -----------------------------------------------------------
  Future<void> uploadToLambda(File imageFile) async {
    final url = Uri.parse(
      "https://qc9d7iywlh.execute-api.us-east-1.amazonaws.com/prod/upload",
    );

    setState(() => _isUploading = true);

    try {
      final compressedBytes = await FlutterImageCompress.compressWithFile(
        imageFile.absolute.path,
        quality: 70,
        minWidth: 1920,
        minHeight: 1080,
        format: CompressFormat.jpeg,
      );

      if (compressedBytes == null) {
        throw Exception("Compression failed");
      }

      final originalSize = (await imageFile.readAsBytes()).length;
      print("📊 Original size: ${(originalSize / 1024).toStringAsFixed(1)} KB");
      print("📊 Compressed size: ${(compressedBytes.length / 1024).toStringAsFixed(1)} KB");

      final base64Image = base64Encode(compressedBytes);

      final payload = jsonEncode({
        "fileName": "photo_${DateTime.now().millisecondsSinceEpoch}.jpg",
        "fileData": base64Image,
        "metadata": {
          "timestamp": _timestamp?.toIso8601String(),
          "originalSizeBytes": _fileSizeBytes,
          "compressedSizeBytes": compressedBytes.length,
          "width": _width,
          "height": _height,
          "deviceInfo": _deviceInfo,
          "location": _location,
        }
      });

      final response = await http.post(
        url,
        headers: {"Content-Type": "application/json"},
        body: payload,
      ).timeout(
        Duration(seconds: 30),
        onTimeout: () {
          throw TimeoutException("Upload timeout");
        },
      );

      if (response.statusCode == 200) {
        // Parse response to get S3 URL
        final responseData = jsonDecode(response.body);
        final s3Url = responseData['url'] ?? responseData['s3Url'] ?? 'URL not provided';
        
        print("✅ Upload successful!");
        print("📎 S3 URL: $s3Url");
        print("📦 Response: ${response.body}");
        
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Row(
                children: [
                  Icon(Icons.check_circle, color: Colors.white),
                  SizedBox(width: 12),
                  Expanded(child: Text("Photo uploaded successfully!")),
                ],
              ),
              backgroundColor: Color(0xFF4CAF50), // Green color
              behavior: SnackBarBehavior.floating,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
          );
        }
      } else {
        throw Exception("Upload failed: ${response.statusCode}");
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Row(
              children: [
                Icon(Icons.error_outline, color: Colors.white),
                SizedBox(width: 12),
                Expanded(child: Text("Upload failed: ${e.toString()}")),
              ],
            ),
            backgroundColor: Color(0xFF404040),
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _isUploading = false);
      }
    }
  }

  // -----------------------------------------------------------
  // 📌 SHOW METADATA
  // -----------------------------------------------------------
  void _showMetadata() {
    if (!_metadataReady) return;

    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (_) {
        return Container(
          decoration: BoxDecoration(
            color: Color(0xFF1A1A1A),
            borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
          ),
          padding: EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: Colors.grey[700],
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              SizedBox(height: 20),
              Text(
                "Photo Details",
                style: TextStyle(
                  fontSize: 24,
                  fontWeight: FontWeight.bold,
                  color: Colors.white,
                ),
              ),
              SizedBox(height: 20),
              _metaCard(Icons.access_time, "Captured", _timestamp.toString()),
              _metaCard(Icons.file_present, "File Size", "${(_fileSizeBytes! / 1024).toStringAsFixed(1)} KB"),
              _metaCard(Icons.aspect_ratio, "Resolution", "$_width × $_height"),
              if (_deviceInfo.isNotEmpty) _metaCard(Icons.phone_android, "Device", _deviceInfo),
              if (_location.isNotEmpty) _metaCard(Icons.location_on, "Location", _location),
              SizedBox(height: 20),
            ],
          ),
        );
      },
    );
  }

  Widget _metaCard(IconData icon, String title, String value) {
    return Container(
      margin: EdgeInsets.only(bottom: 12),
      padding: EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Color(0xFF2A2A2A),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Color(0xFF404040)),
      ),
      child: Row(
        children: [
          Container(
            padding: EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: Color(0xFF404040),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(icon, color: Colors.white70, size: 20),
          ),
          SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    color: Colors.grey[500],
                    fontSize: 12,
                  ),
                ),
                SizedBox(height: 4),
                Text(
                  value,
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // -----------------------------------------------------------
  // 📌 RESET
  // -----------------------------------------------------------
  void _discardPhoto() {
    setState(() {
      _image = null;
      _metadataReady = false;
      _timestamp = null;
      _fileSizeBytes = null;
      _width = null;
      _height = null;
      _deviceInfo = "";
      _location = "";
    });
    _pulseController.repeat(reverse: true); // Restart pulse animation
  }

  // -----------------------------------------------------------
  // 📌 UPLOAD WRAPPER
  // -----------------------------------------------------------
  Future<void> uploadImageToServer() async {
    if (_image == null) return;
    await uploadToLambda(_image!);
  }

  // -----------------------------------------------------------
  // UI
  // -----------------------------------------------------------
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
        color: Color(0xFF0A0A0A),
        child: SafeArea(
          child: Column(
            children: [
              // Header
              Padding(
                padding: EdgeInsets.all(20),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          "PhotoSync",
                          style: TextStyle(
                            fontSize: 28,
                            fontWeight: FontWeight.bold,
                            color: Colors.white,
                          ),
                        ),
                        Text(
                          "Capture & Upload",
                          style: TextStyle(
                            fontSize: 14,
                            color: Colors.grey[600],
                          ),
                        ),
                      ],
                    ),
                    if (_metadataReady)
                      Container(
                        decoration: BoxDecoration(
                          color: Color(0xFF2A2A2A),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: IconButton(
                          icon: Icon(Icons.info_outline, color: Colors.white70),
                          onPressed: _showMetadata,
                        ),
                      ),
                  ],
                ),
              ),

              Expanded(
                child: Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      // Photo Container
                      GestureDetector(
                        onTap: _isUploading ? null : pickImage,
                        child: FadeTransition(
                          opacity: _fadeAnimation,
                          child: ScaleTransition(
                            scale: _image == null ? _pulseAnimation : AlwaysStoppedAnimation(1.0),
                            child: Container(
                              height: 420,
                              width: 320,
                              decoration: BoxDecoration(
                                borderRadius: BorderRadius.circular(24),
                                color: _image == null ? Color(0xFF1A1A1A) : null,
                                border: Border.all(
                                  color: _image == null ? Color(0xFF2A2A2A) : Colors.transparent,
                                  width: 2,
                                ),
                                boxShadow: _image == null
                                    ? [
                                        BoxShadow(
                                          color: Colors.black.withOpacity(0.3),
                                          blurRadius: 20,
                                          spreadRadius: 2,
                                        ),
                                      ]
                                    : null,
                              ),
                              child: _image == null
                                  ? Column(
                                      mainAxisAlignment: MainAxisAlignment.center,
                                      children: [
                                        Container(
                                          padding: EdgeInsets.all(24),
                                          decoration: BoxDecoration(
                                            color: Color(0xFF2A2A2A),
                                            shape: BoxShape.circle,
                                          ),
                                          child: Icon(
                                            Icons.camera_alt,
                                            size: 64,
                                            color: Colors.white70,
                                          ),
                                        ),
                                        SizedBox(height: 24),
                                        Text(
                                          "Tap to capture",
                                          style: TextStyle(
                                            fontSize: 18,
                                            fontWeight: FontWeight.w500,
                                            color: Colors.white,
                                          ),
                                        ),
                                        SizedBox(height: 8),
                                        Container(
                                          padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                                          decoration: BoxDecoration(
                                            color: Color(0xFF2A2A2A),
                                            borderRadius: BorderRadius.circular(20),
                                          ),
                                          child: Row(
                                            mainAxisSize: MainAxisSize.min,
                                            children: [
                                              Icon(
                                                Icons.touch_app,
                                                size: 16,
                                                color: Colors.grey[500],
                                              ),
                                              SizedBox(width: 6),
                                              Text(
                                                "Tap anywhere",
                                                style: TextStyle(
                                                  fontSize: 13,
                                                  color: Colors.grey[500],
                                                ),
                                              ),
                                            ],
                                          ),
                                        ),
                                      ],
                                    )
                                  : ClipRRect(
                                      borderRadius: BorderRadius.circular(24),
                                      child: Image.file(
                                        _image!,
                                        fit: BoxFit.cover,
                                      ),
                                    ),
                            ),
                          ),
                        ),
                      ),

                      SizedBox(height: 40),

                      // Action Buttons
                      if (_image != null)
                        Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            // Discard Button
                            Container(
                              decoration: BoxDecoration(
                                color: Color(0xFF2A2A2A),
                                borderRadius: BorderRadius.circular(16),
                                border: Border.all(
                                  color: Color(0xFF404040),
                                ),
                              ),
                              child: IconButton(
                                icon: Icon(Icons.close, size: 28),
                                color: Colors.white70,
                                onPressed: _isUploading ? null : _discardPhoto,
                              ),
                            ),

                            SizedBox(width: 30),

                            // Upload Button
                            _isUploading
                                ? Container(
                                    padding: EdgeInsets.all(16),
                                    decoration: BoxDecoration(
                                      color: Color(0xFF2A2A2A),
                                      borderRadius: BorderRadius.circular(16),
                                    ),
                                    child: SizedBox(
                                      width: 28,
                                      height: 28,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 3,
                                        valueColor: AlwaysStoppedAnimation(Colors.white),
                                      ),
                                    ),
                                  )
                                : Container(
                                    decoration: BoxDecoration(
                                      color: Color(0xFF2A2A2A),
                                      borderRadius: BorderRadius.circular(16),
                                      border: Border.all(
                                        color: Color(0xFF404040),
                                      ),
                                    ),
                                    child: IconButton(
                                      icon: Icon(Icons.cloud_upload, size: 28),
                                      color: Colors.white,
                                      onPressed: uploadImageToServer,
                                    ),
                                  ),
                          ],
                        ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}