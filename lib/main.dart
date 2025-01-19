import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'package:dart_appwrite/dart_appwrite.dart';
import 'package:mailer/mailer.dart';
import 'package:mailer/smtp_server.dart';
import 'package:uuid/uuid.dart';

final String appwriteEndpoint = "https://cloud.appwrite.io/v1";
final String projectId = "678a44f60021a266d10c";
final String databaseId = "6717388600333d9d6235";
final String userCollectionId = '6717d17b0019f7ec1a83';
final String userFileBukectId = "67188621002cc7456b26";
final String otpCollectionId = "6718f9ed001ed7ba1571";
final String tokensCollectionId = "671c710b0012aaa043cc";
Future<dynamic> main(final context) async {
  final client = Client()
      .setEndpoint(Platform.environment['APPWRITE_FUNCTION_API_ENDPOINT'] ?? '')
      .setProject(Platform.environment['APPWRITE_FUNCTION_PROJECT_ID'] ?? '')
      .setKey(context.req.headers['x-appwrite-key'] ??
          'standard_fc2bbbf53dd7c339c0bc1b58498381800d4aa830687c7682c3024949f50f6b7a4fde0d655726164314f642ba74abec5dbd968044f41924bbc6d1d9aba5906d92c4301bf614da1cec86c6ee302f0f5b9d4366ab235dfdcad629a401e4beb16b4b1f68a2d84715807e1999ab8c689f9f91b5aed05089c7a803c96fedf8664d439f');

  final database = Databases(client);

  if (context.req.method == 'GET') {
    return context.res.text('Hello, World!');
  }

  if (context.req.method == 'POST') {
    final data = context.req.bodyJson;

    if (data['action'] == 'sendOtp') {
      return await sendOtp(context, database, data);
    } else if (data['action'] == 'verifyOtp') {
      return await verifyOtpForRecovery(context, database, data, client);
    } else if (data['action'] == 'updatePassword') {
      return await updatePassword(context, database, data, client);
    } else {
      return context.res.json({
        'message':
            "Invalid action. Use 'sendOtp', 'verifyOtp', or 'updatePassword'.",
      });
    }
  }

  return context.res.json({
    'message': "Invalid request method. Use POST.",
  });
}

// Function to send OTP
Future<dynamic> sendOtp(
    final context, Databases database, Map<String, dynamic> data) async {
  String? email = data['email'];
  bool? isFirstVerify = data['isFirstVerify'];

  if (email == null) {
    return context.res.json({
      'message': "Invalid request. 'email'  fields are required.",
    });
  }

  try {
    // Check for existing OTP document
    final existingOtpResponse = await database.listDocuments(
      databaseId: databaseId,
      collectionId: otpCollectionId,
      queries: [
        Query.equal('email', email),
      ],
    );

    // Delete existing OTP document if found
    if (existingOtpResponse.documents.isNotEmpty) {
      final existingOtpDocument = existingOtpResponse.documents.first;
      await database.deleteDocument(
        databaseId: databaseId,
        collectionId: otpCollectionId,
        documentId: existingOtpDocument.$id, // Use the existing document ID
      );
      context.log('Existing OTP document deleted.');
    }
    final otp = (Random().nextInt(9000) + 1000).toString();
    final otpType =
        isFirstVerify == true ? 'verification' : 'password_recovery';

    // Save OTP to Database
    await database.createDocument(
      databaseId: databaseId, // Replace with your database ID
      collectionId: otpCollectionId, // Replace with your OTP collection ID
      documentId: 'unique()', // Generate a unique document ID
      data: {
        'email': email,
        'otp': otp,
        'type': otpType,
        'created_at': DateTime.now().toUtc().toIso8601String(),
        'expires_at':
            DateTime.now().toUtc().add(Duration(minutes: 5)).toIso8601String(),
      },
    );

    final userdoc = await database.listDocuments(
      databaseId: databaseId, // Replace with your database ID
      collectionId: userCollectionId,
      // Replace with your OTP collection ID
      queries: [
        Query.equal('email', email),
      ],
    );
    final user = userdoc.documents.first;

    await sendMails(email, user.data["fullName"], otp,
        isFirstVerify: isFirstVerify ?? true);
    context.log('Email sent and OTP saved successfully!');
    return context.res.json({
      "status": true,
      'message': "Email sent and OTP saved successfully!",
    });
  } catch (e) {
    context.log('Error sending email or saving OTP: $e');
    return context.res.json({
      'message': "Error: $e",
    });
  }
}

Future sendMails(String email, String username, String otp,
    {bool isFirstVerify = true}) async {
  final smtpServer = gmail("carbonkonnect@gmail.com", "jxwn bblj rvvq twts");

  final subject = isFirstVerify
      ? "Welcome to Cabon Connect - Verify Your Email"
      : "Cabon Connect - Password Recovery OTP";

  final bodyText = isFirstVerify
      ? """
        <h2 style="color: #4CAF50;">Hello, $username!</h2>
        <p>Welcome to <strong>Cabon Connect</strong>! Please verify your email to complete the sign-up process.</p>
        <p>Your OTP for verification is:</p>
      """
      : """
        <h2 style="color: #4CAF50;">Hello, $username!</h2>
        <p>We received a request to reset your password for your <strong>Cabon Connect</strong> account.</p>
        <p>Your OTP for password recovery is:</p>
      """;

  final message = Message()
    ..from = Address("eucloudhost@gmail.com", "Cabon Connect")
    ..recipients.add(email)
    ..subject = subject
    ..html = """
    <html>
      <body style="font-family: Arial, sans-serif; color: #333;">
        $bodyText
        <h1 style="color: #333; background-color: #f9f9f9; padding: 10px; border-radius: 5px; display: inline-block;">$otp</h1>
        <p style="margin-top: 20px;">If you did not request this code, please ignore this email.</p>
        <br>
        <p>Regards,<br>
        Cabon Connect Team</p>
      </body>
    </html>
    """;

  try {
    await send(message, smtpServer);
    print("Email sent to $email with OTP: $otp");
  } on MailerException catch (e) {
    print("Error sending email: $e");
  }
}

// Make sure to include this in your pubspec.yaml

Future<dynamic> verifyOtpForRecovery(final context, Databases database,
    Map<String, dynamic> data, Client client) async {
  String? email = data['email'];
  String? otp = data['otp'];

  if (email == null || otp == null) {
    return context.res.json({
      'message': "Invalid request. 'email' and 'otp' fields are required.",
    });
  }

  try {
    // Retrieve the OTP Document

    final response = await database.listDocuments(
      databaseId: databaseId, // Replace with your database ID
      collectionId: otpCollectionId,
      // Replace with your OTP collection ID
      queries: [
        Query.equal('email', email),
        Query.equal('otp', otp),
      ],
    );

    if (response.documents.isEmpty) {
      return context.res.json({
        'status': false,
        'message': 'Invalid OTP or email.',
      });
    }

    // Get the OTP document and check expiration
    final otpDocument = response.documents.first;
    DateTime expiresAt = DateTime.parse(otpDocument.data['expires_at']);

    if (DateTime.now().isAfter(expiresAt)) {
      await database.deleteDocument(
        databaseId: databaseId,
        collectionId: otpCollectionId,
        documentId: otpDocument.$id,
      );
      return context.res.json({
        'status': false,
        'message': 'OTP has expired.',
      });
    }

    if (otpDocument.data["type"] == "verification") {
      final users = Users(client);

      final userdoc = await database.listDocuments(
        databaseId: databaseId, // Replace with your database ID
        collectionId: userCollectionId,
        // Replace with your OTP collection ID
        queries: [
          Query.equal('email', email),
        ],
      );
      final user = userdoc.documents.first;

      await users.updateEmailVerification(
          userId: user.$id, emailVerification: true);
      await users
          .updateLabels(userId: user.$id, labels: ["${user.data['role']}"]);

      await database.deleteDocument(
        databaseId: databaseId,
        collectionId: otpCollectionId,
        documentId: otpDocument.$id,
      );
      // Successful Verification
      return context.res.json({
        'status': true,
        'message': 'User verified successfully!',
      });
    }

    final userdoc = await database.listDocuments(
      databaseId: databaseId, // Replace with your database ID
      collectionId: userCollectionId,
      // Replace with your OTP collection ID
      queries: [
        Query.equal('email', email),
      ],
    );
    final user = userdoc.documents.first;

    final tokens = await database.listDocuments(
      databaseId: databaseId, // Replace with your database ID
      collectionId: tokensCollectionId,
      // Replace with your OTP collection ID
      queries: [
        Query.equal('email', email),
      ],
    );
    try {
      final tokenId =
          tokens.documents.where((ed) => ed.data["email"] == email).toList();

      for (var element in tokenId) {
        await database.deleteDocument(
          databaseId: databaseId,
          collectionId: element.$collectionId,
          documentId: element.$id,
        );
      }
    } catch (e) {}

    // Generate a token
    String token = Uuid().v4(); // Generate a unique token
    // Save the token to the database
    await database.createDocument(
      databaseId: databaseId, // Replace with your database ID
      collectionId:
          tokensCollectionId, // Create a tokensCollectionId collection
      documentId: token, // Use the generated token as the document ID
      data: {
        "userId": user.$id,
        'email': email,
        'expires_at': DateTime.now()
            .add(Duration(hours: 1))
            .toIso8601String(), // Token expiration time
      },
    );

    return context.res.json({
      'status': true,
      'token': token, // Send the token back to the user
      'message':
          'OTP verified successfully! Use this token to update your password.',
    });
  } catch (e) {
    context.log('Error verifying OTP: $e');
    return context.res.json({
      'message': "Error: $e",
    });
  }
}

Future<dynamic> updatePassword(final context, Databases database,
    Map<String, dynamic> data, Client client) async {
  String? email = data['email'];
  String? newPassword = data['new_password'];
  String? token = data['token']; // Get the token from the request

  if (email == null || newPassword == null || token == null) {
    return context.res.json({
      'message':
          "Invalid request. 'email', 'new_password', and 'token' fields are required.",
    });
  }

  try {
    // Verify the token
    final tokenResponse = await database.listDocuments(
      databaseId: databaseId, // Replace with your database ID
      collectionId: tokensCollectionId, // Tokens collection
      queries: [
        Query.equal('email', email),
      ],
    );

    if (tokenResponse.documents.isEmpty) {
      return context.res.json({
        'status': false,
        'message': 'Invalid token or email.',
      });
    }

    // Check if the token has expired
    final tokenDocument = tokenResponse.documents.first;
    DateTime tokenExpiresAt = DateTime.parse(tokenDocument.data['expires_at']);

    if (DateTime.now().isAfter(tokenExpiresAt)) {
      return context.res.json({
        'status': false,
        'message': 'Token has expired.',
      });
    }

    // Here you would typically update the user's password in your users' collection.
    final users = Users(client);

    // Find the user by email and update the password
    await users.updatePassword(
        userId: tokenDocument.data["userId"], password: newPassword);

    // Optionally, delete the token after successful password update
    await database.deleteDocument(
      databaseId: databaseId,
      collectionId: tokensCollectionId,
      documentId: token,
    );

    return context.res.json({
      'status': true,
      'message': 'Password updated successfully!',
    });
  } catch (e) {
    context.log('Error updating password: $e');
    return context.res.json({
      'message': "Error: $e",
    });
  }
}
