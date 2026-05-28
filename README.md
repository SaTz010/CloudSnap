# PhotoSync

PhotoSync is a Flutter camera app that captures a photo, collects useful metadata, compresses the image, and uploads it to an AWS API Gateway/Lambda endpoint.

## Features

- Capture a new photo from the device camera.
- Preview the captured image in a dark Material 3 interface.
- Discard the current photo and capture again.
- View photo metadata in a bottom sheet.
- Compress the captured image before upload.
- Upload the photo and metadata as JSON.
- Show success and failure feedback with snackbars.

## Metadata Collected

After a photo is captured, the app collects:

- Capture timestamp
- Original file size
- Image width and height
- Android device model and SDK version
- Current latitude and longitude, when location permission is available

If location services or permissions are unavailable, the app records that status instead of coordinates.

## Tech Stack

- Flutter and Dart
- Material 3 dark theme
- `image_picker` for camera capture
- `geolocator` for location
- `device_info_plus` for device details
- `flutter_image_compress` for JPEG compression
- `http` for API upload requests

## Upload Flow

The upload logic is implemented in `lib/main.dart` inside `uploadToLambda`.

The app compresses the selected image to JPEG using:

- Quality: `70`
- Minimum width: `1920`
- Minimum height: `1080`

It then sends a `POST` request to the configured AWS endpoint with a JSON payload:

```json
{
  "fileName": "photo_<timestamp>.jpg",
  "fileData": "<base64-compressed-jpeg>",
  "metadata": {
    "timestamp": "<iso-date>",
    "originalSizeBytes": 0,
    "compressedSizeBytes": 0,
    "width": 0,
    "height": 0,
    "deviceInfo": "<device model and sdk>",
    "location": "<latitude, longitude or status>"
  }
}
```

A successful upload expects an HTTP `200` response. The app also checks the response body for `url` or `s3Url` and logs it when present.

## Project Structure

- `lib/main.dart` - main application UI, camera capture, metadata collection, compression, and upload logic
- `pubspec.yaml` - Flutter dependencies and project configuration
- `android/app/src/main/AndroidManifest.xml` - Android permissions and app entry point
- `ios/Runner/Info.plist` - iOS app metadata and permission strings

## Permissions

The app needs camera, location, and network access.

Android currently declares:

- `android.permission.CAMERA`
- `android.permission.ACCESS_FINE_LOCATION`
- `android.permission.ACCESS_COARSE_LOCATION`
- `android.permission.ACCESS_BACKGROUND_LOCATION`

For Android release uploads, ensure `android.permission.INTERNET` is also declared in `android/app/src/main/AndroidManifest.xml`.

iOS currently declares `NSCameraUsageDescription`. Because the app also requests location, add an iOS location usage description such as `NSLocationWhenInUseUsageDescription` before running the location feature on iOS.

## Getting Started

Install dependencies:

```sh
flutter pub get
```

Run the app:

```sh
flutter run
```

Use a physical device or an emulator/simulator with camera and location support for the full capture and metadata flow.

## Configuration Notes

- The upload endpoint is currently hard-coded in `lib/main.dart`.
- The device information code currently reads Android device info with `DeviceInfoPlugin().androidInfo`.
- The app captures photos from the camera only; it does not currently select images from the gallery.
