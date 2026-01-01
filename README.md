# Google Auth Function

Appwrite Cloud Function for native Google Sign-In authentication.

This function validates Google ID tokens from native Android/iOS sign-in and creates Appwrite sessions.

## How It Works

1. User signs in with Google using native account picker (no browser redirect)
2. Flutter app gets Google ID token
3. App calls this function with the token
4. Function verifies token with Google
5. Function creates/finds user in Appwrite
6. Returns JWT for session authentication

## Environment Variables

| Variable | Description | Example |
|----------|-------------|---------|
| `APPWRITE_API_KEY` | Appwrite API key with users.read, users.write, databases.read, databases.write | `your-api-key` |
| `DATABASE_ID` | Your database ID | `695534670020c39eb399` |
| `USERS_COLLECTION` | Users collection ID | `users` |
| `GOOGLE_CLIENT_ID` | Your Google OAuth Client ID | `xxx.apps.googleusercontent.com` |

## Setup Google OAuth Client ID

1. Go to [Google Cloud Console](https://console.cloud.google.com)
2. Create or select a project
3. Go to **APIs & Services** > **Credentials**
4. Create **OAuth 2.0 Client ID**:
   - For Android: Select "Android" type
   - Package name: `com.dajaja`
   - SHA-1: Your debug/release certificate fingerprint
5. Copy the Client ID

## Deployment

### Option 1: Appwrite CLI

```bash
cd appwrite_functions/google_auth
npm install
appwrite deploy function
```

### Option 2: GitHub Integration

Connect this repo to Appwrite Functions and it will auto-deploy.

## Database Requirements

Your `users` collection must have:
- `name` (string)
- `email` (string)
- `role` (string)
- `kyc_status` (string)
- `is_subscribed` (boolean)
- `profile_image` (string, optional)
