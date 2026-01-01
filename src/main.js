const sdk = require('node-appwrite');
const { OAuth2Client } = require('google-auth-library');

module.exports = async ({ req, res, log, error }) => {
  try {
    log('🔐 Google Auth Function started');
    log('📦 Request body: ' + JSON.stringify(req.body));

    const { idToken, accessToken } = typeof req.body === 'string' 
      ? JSON.parse(req.body) 
      : req.body;

    if (!idToken) {
      error('❌ No ID token provided');
      return res.json({ success: false, error: 'No ID token provided' });
    }

    // Verify the Google ID token
    const googleClientId = process.env.GOOGLE_CLIENT_ID;
    const oauthClient = new OAuth2Client(googleClientId);

    log('🔍 Verifying Google ID token...');
    
    const ticket = await oauthClient.verifyIdToken({
      idToken: idToken,
      audience: googleClientId,
    });

    const payload = ticket.getPayload();
    log('✅ Token verified for: ' + payload.email);

    const userId = payload.sub; // Google user ID
    const email = payload.email;
    const name = payload.name || email.split('@')[0];
    const picture = payload.picture;

    // Initialize Appwrite Admin client
    const client = new sdk.Client()
      .setEndpoint(process.env.APPWRITE_ENDPOINT)
      .setProject(process.env.APPWRITE_FUNCTION_PROJECT_ID)
      .setKey(process.env.APPWRITE_API_KEY);

    const users = new sdk.Users(client);
    const databases = new sdk.Databases(client);

    let appwriteUser;

    // Check if user exists by email
    try {
      log('🔍 Checking if user exists...');
      const existingUsers = await users.list([
        sdk.Query.equal('email', email)
      ]);

      if (existingUsers.users.length > 0) {
        appwriteUser = existingUsers.users[0];
        log('✅ User found: ' + appwriteUser.$id);
      }
    } catch (e) {
      log('⚠️ Error checking user: ' + e.message);
    }

    // Create user if doesn't exist
    if (!appwriteUser) {
      try {
        log('👤 Creating new user...');
        appwriteUser = await users.create(
          sdk.ID.unique(),
          email,
          undefined, // phone
          undefined, // password
          name
        );
        log('✅ User created: ' + appwriteUser.$id);

        // Create user document in database
        const databaseId = process.env.DATABASE_ID;
        const usersCollection = process.env.USERS_COLLECTION || 'users';

        await databases.createDocument(
          databaseId,
          usersCollection,
          appwriteUser.$id,
          {
            name: name,
            email: email,
            role: 'buyer', // Default role
            kyc_status: 'pending',
            is_subscribed: false,
            profile_image: picture || '',
          }
        );
        log('✅ User document created');

      } catch (e) {
        error('❌ Error creating user: ' + e.message);
        return res.json({ success: false, error: 'Failed to create user: ' + e.message });
      }
    }

    // Create a magic URL token for the user to create a session
    try {
      log('🔑 Creating session token...');
      
      // Create a token that the client can use to create a session
      // Using createToken with a custom secret
      const token = await users.createToken(appwriteUser.$id);
      
      log('✅ Token created successfully');

      return res.json({
        success: true,
        userId: appwriteUser.$id,
        email: email,
        token: token.secret,
        message: 'Login successful'
      });

    } catch (e) {
      error('❌ Error creating token: ' + e.message);
      
      // Fallback: return user info without token
      // Client will need to use OAuth2 to complete login
      return res.json({
        success: true,
        userId: appwriteUser.$id,
        email: email,
        needsOAuth: true,
        message: 'User created, needs OAuth to complete login'
      });
    }

  } catch (e) {
    error('❌ Error: ' + e.message);
    return res.json({ success: false, error: e.message });
  }
};
