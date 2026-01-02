import 'dart:convert';
import 'dart:io';
import 'package:dart_appwrite/dart_appwrite.dart';
import 'package:dart_appwrite/models.dart' as models;

final String? endpoint = Platform.environment['APPWRITE_ENDPOINT'];
final String? projectId = Platform.environment['APPWRITE_FUNCTION_PROJECT_ID'];
final String? apiKey = Platform.environment['APPWRITE_API_KEY'];
final String? databaseId = Platform.environment['DATABASE_ID'];
final String? usersCollection = Platform.environment['USERS_COLLECTION'];

Client _adminClient() => Client()
  ..setEndpoint(endpoint ?? 'https://fra.cloud.appwrite.io/v1')
  ..setProject(projectId ?? '')
  ..setKey(apiKey ?? '');

/// Helper to return JSON response
dynamic _jsonResponse(dynamic context, Map<String, dynamic> data, {int statusCode = 200}) {
  return context.res.send(
    jsonEncode(data),
    statusCode,
    {'content-type': 'application/json'},
  );
}

// Entry point for Appwrite Function
Future<dynamic> main(final context) async {
  try {
    context.log('🔐 Google Auth Function started');
    
    final trigger = context.req.headers['x-appwrite-trigger'] ?? '';
    
    if (trigger == 'http') {
      context.log('🌐 HTTP request received');
      
      Map<String, dynamic> data = <String, dynamic>{};
      final body = context.req.body;
      
      if (body is String && body.isNotEmpty) {
        data = jsonDecode(body) as Map<String, dynamic>;
      } else if (body is Map) {
        data = Map<String, dynamic>.from(body);
      }

      context.log('📦 Payload: ${jsonEncode(data)}');

      final actionType = (data['action_type'] ?? '').toString().trim();

      // Handle Google Native Sign-In
      if (actionType == 'google_native_signin') {
        context.log('🔐 Google Native Sign-In request received');
        return await _handleGoogleNativeSignIn(context, data);
      }

      // Default: treat as legacy format (without action_type)
      if (data['id_token'] != null || data['idToken'] != null) {
        context.log('🔐 Legacy Google Sign-In format detected');
        return await _handleGoogleNativeSignIn(context, data);
      }

      return _jsonResponse(context, {
        'status': 'error',
        'message': 'Unknown action type',
      }, statusCode: 400);
    }

    return _jsonResponse(context, {'status': 'ok', 'message': 'Trigger ignored'});
  } catch (e, stack) {
    context.error('❌ Function error: $e');
    context.error('Stack trace: $stack');
    return _jsonResponse(context, {
      'status': 'error',
      'message': e.toString(),
    }, statusCode: 500);
  }
}

/// Handle Google Native Sign-In
Future<dynamic> _handleGoogleNativeSignIn(
  dynamic context,
  Map<String, dynamic> payload,
) async {
  final client = _adminClient();
  final users = Users(client);
  final databases = Databases(client);

  // Support both snake_case and camelCase
  final String? idToken = payload['id_token'] ?? payload['idToken'];
  final String? email = payload['email'];
  final String? name = payload['name'] ?? payload['displayName'];
  final String? picture = payload['picture'] ?? payload['photoUrl'];

  if (idToken == null || idToken.isEmpty) {
    return _jsonResponse(context, {
      'status': 'error',
      'message': 'Google ID token is required',
    }, statusCode: 400);
  }

  context.log('🔐 Verifying Google ID token...');

  try {
    // Step 1: Verify the Google ID token
    final googleUserInfo = await _verifyGoogleToken(idToken, context);

    if (googleUserInfo == null) {
      return _jsonResponse(context, {
        'status': 'error',
        'message': 'Invalid Google token',
      }, statusCode: 401);
    }

    final String verifiedEmail = googleUserInfo['email'] ?? email ?? '';
    final String verifiedName = googleUserInfo['name'] ?? name ?? verifiedEmail.split('@')[0];
    final String? verifiedPicture = googleUserInfo['picture'] ?? picture;
    final String googleUserId = googleUserInfo['sub'] ?? '';

    context.log('✅ Google token verified for: $verifiedEmail');

    // Step 2: Check if user already exists
    models.User? existingUser;
    try {
      final usersList = await users.list(
        queries: [Query.equal('email', verifiedEmail)],
      );

      if (usersList.users.isNotEmpty) {
        existingUser = usersList.users.first;
        context.log('👤 Existing user found: ${existingUser.$id}');
      }
    } catch (e) {
      context.log('⚠️ Error searching for user: $e');
    }

    String appwriteUserId;

    if (existingUser != null) {
      appwriteUserId = existingUser.$id;

      // Ensure email is verified
      if (!existingUser.emailVerification) {
        try {
          await users.updateEmailVerification(
            userId: appwriteUserId,
            emailVerification: true,
          );
          context.log('✅ Existing user email marked as verified');
        } catch (e) {
          context.log('⚠️ Failed to verify existing user email: $e');
        }
      }
    } else {
      // Step 3: Create new user
      context.log('🆕 Creating new user...');

      try {
        final newUser = await users.create(
          userId: ID.unique(),
          email: verifiedEmail,
          name: verifiedName,
          password: 'google_oauth_${googleUserId}_${DateTime.now().millisecondsSinceEpoch}',
        );

        appwriteUserId = newUser.$id;
        context.log('✅ New user created: $appwriteUserId');

        // Mark email as verified
        try {
          await users.updateEmailVerification(
            userId: appwriteUserId,
            emailVerification: true,
          );
          context.log('✅ Email marked as verified');
        } catch (e) {
          context.log('⚠️ Failed to verify email: $e');
        }

        // Create user document in database
        if (databaseId != null && usersCollection != null) {
          try {
            await databases.createDocument(
              databaseId: databaseId!,
              collectionId: usersCollection!,
              documentId: appwriteUserId,
              data: {
                'name': verifiedName,
                'email': verifiedEmail,
                'phone': '',
                'role': 'buyer',
                'kyc_status': 'pending',
                'is_subscribed': false,
                'profile_image': verifiedPicture ?? '',
                'created_at': DateTime.now().toUtc().toIso8601String(),
              },
            );
            context.log('✅ User document created');
          } catch (e) {
            context.log('⚠️ Error creating user document: $e');
          }
        }
      } catch (e) {
        if (e is AppwriteException && e.code == 409) {
          // User already exists (race condition)
          final usersList = await users.list(
            queries: [Query.equal('email', verifiedEmail)],
          );
          if (usersList.users.isNotEmpty) {
            appwriteUserId = usersList.users.first.$id;
            context.log('👤 User found after conflict: $appwriteUserId');
          } else {
            throw Exception('Could not create or find user');
          }
        } else {
          throw e;
        }
      }
    }

    // Step 4: Create a session token
    context.log('🎫 Creating session token...');

    try {
      final token = await users.createToken(
        userId: appwriteUserId,
      );

      context.log('✅ Session token created');

      return _jsonResponse(context, {
        'status': 'ok',
        'success': true,
        'user_id': appwriteUserId,
        'userId': appwriteUserId,
        'secret': token.secret,
        'token': token.secret,
        'expire': token.expire,
        'email': verifiedEmail,
        'name': verifiedName,
        'picture': verifiedPicture,
      });
    } catch (e) {
      context.error('❌ Failed to create session token: $e');

      return _jsonResponse(context, {
        'status': 'partial',
        'success': true,
        'user_id': appwriteUserId,
        'userId': appwriteUserId,
        'email': verifiedEmail,
        'name': verifiedName,
        'needsOAuth': true,
        'message': 'User verified but session creation failed. Use browser OAuth.',
      });
    }
  } catch (e) {
    context.error('❌ Google Sign-In error: $e');
    return _jsonResponse(context, {
      'status': 'error',
      'message': 'Google Sign-In failed: $e',
    }, statusCode: 500);
  }
}

/// Verify Google ID token
Future<Map<String, dynamic>?> _verifyGoogleToken(String idToken, dynamic context) async {
  try {
    final httpClient = HttpClient();

    final request = await httpClient.getUrl(
      Uri.parse('https://oauth2.googleapis.com/tokeninfo?id_token=$idToken'),
    );

    final response = await request.close();

    if (response.statusCode == 200) {
      final responseBody = await response.transform(utf8.decoder).join();
      final data = jsonDecode(responseBody) as Map<String, dynamic>;

      if (data['email_verified'] != 'true' && data['email_verified'] != true) {
        context.log('⚠️ Email not verified');
        return null;
      }

      // Decode JWT to get picture
      try {
        final parts = idToken.split('.');
        if (parts.length == 3) {
          String payload = parts[1];
          while (payload.length % 4 != 0) {
            payload += '=';
          }
          final decoded = utf8.decode(base64Url.decode(payload));
          final jwtPayload = jsonDecode(decoded) as Map<String, dynamic>;

          if (jwtPayload['picture'] != null) {
            data['picture'] = jwtPayload['picture'];
          }
          if (data['name'] == null && jwtPayload['name'] != null) {
            data['name'] = jwtPayload['name'];
          }
        }
      } catch (e) {
        context.log('⚠️ Could not decode JWT for picture: $e');
      }

      return data;
    } else {
      context.log('❌ Google token verification failed: ${response.statusCode}');
      return null;
    }
  } catch (e) {
    context.error('❌ Error verifying Google token: $e');
    return null;
  }
}
