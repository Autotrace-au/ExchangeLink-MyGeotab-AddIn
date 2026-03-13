# FleetBridge SaaS Architecture - Multi-Tenant Design

## Overview

FleetBridge is a **true SaaS application** where:
- Clients install the Add-In from MyGeotab Marketplace
- **No Azure/Entra setup required** for clients
- One-click consent grants FleetBridge access to their Exchange
- All processing happens in **your (Autotrace) tenant**

---

## Architecture Diagram

```
┌─────────────────────────────────────────────────────────────────┐
│                    CLIENT A TENANT                               │
│  ┌──────────────────────────────────────────────────────────┐   │
│  │  User opens MyGeotab Add-In                              │   │
│  │  Clicks "Connect to Exchange"                            │   │
│  │  → Redirected to Microsoft consent page                  │   │
│  │  → Grants permissions (one-time)                         │   │
│  │  → Redirected back to Add-In with auth code             │   │
│  └──────────────────────────────────────────────────────────┘   │
│                            ↓                                      │
│  ┌──────────────────────────────────────────────────────────┐   │
│  │  Exchange Online (Client A's tenant)                     │   │
│  │  - Equipment mailboxes                                   │   │
│  │  - Calendar bookings                                     │   │
│  └──────────────────────────────────────────────────────────┘   │
└──────────────────────────┬───────────────────────────────────────┘
                           │
                           │ OAuth 2.0 with delegated permissions
                           │
┌──────────────────────────▼───────────────────────────────────────┐
│                 AUTOTRACE (SERVICE PROVIDER) TENANT              │
│  ┌──────────────────────────────────────────────────────────┐   │
│  │  Multi-Tenant Entra App Registration                     │   │
│  │  - Name: "FleetBridge SaaS"                              │   │
│  │  - Multi-tenant: Yes (any organization)                  │   │
│  │  - Delegated permissions (user consent):                 │   │
│  │    • Calendars.ReadWrite                                 │   │
│  │    • MailboxSettings.ReadWrite                           │   │
│  │    • User.ReadWrite.All                                  │   │
│  │    • EWS.AccessAsUser.All (Exchange)                     │   │
│  └──────────────────────────────────────────────────────────┘   │
│                            ↓                                      │
│  ┌──────────────────────────────────────────────────────────┐   │
│  │  Azure Function App (fleetbridge-mygeotab)               │   │
│  │  - /api/auth/login (OAuth redirect)                      │   │
│  │  - /api/auth/callback (receives tokens)                  │   │
│  │  - /api/update-device-properties                         │   │
│  │  - /api/sync-to-exchange                                 │   │
│  └──────────────────────────────────────────────────────────┘   │
│                            ↓                                      │
│  ┌──────────────────────────────────────────────────────────┐   │
│  │  Azure Key Vault                                         │   │
│  │  - Client A: Refresh token (encrypted)                   │   │
│  │  - Client B: Refresh token (encrypted)                   │   │
│  │  - Client C: Refresh token (encrypted)                   │   │
│  │  - MyGeotab credentials per client                       │   │
│  └──────────────────────────────────────────────────────────┘   │
└──────────────────────────────────────────────────────────────────┘
```

---

## Client Onboarding Flow

### Step 1: Client Installs Add-In

```
1. Client goes to MyGeotab Marketplace
2. Clicks "Install FleetBridge"
3. Add-In appears in their MyGeotab interface
```

### Step 2: First-Time Configuration (One-Time)

**In the Add-In "Sync to Exchange" tab:**

```javascript
// User clicks "Connect to Exchange" button

1. Add-In calls: GET /api/auth/login?clientId=<unique-client-id>

2. Function redirects to Microsoft OAuth consent page:
   https://login.microsoftonline.com/organizations/oauth2/v2.0/authorize
     ?client_id=<your-app-id>
     &response_type=code
    &redirect_uri=https://exchange-calendar-processor.mangosmoke-ee55f1a9.australiaeast.azurecontainerapps.io/api/auth/callback
     &response_mode=query
     &scope=https://graph.microsoft.com/Calendars.ReadWrite
            https://graph.microsoft.com/MailboxSettings.ReadWrite
            https://graph.microsoft.com/User.ReadWrite.All
            offline_access
     &state=<client-id>

3. Client admin sees consent page:
   ┌─────────────────────────────────────────────┐
   │ FleetBridge wants to access your account    │
   │                                             │
   │ This app will be able to:                  │
   │ ✓ Read and write calendars                 │
   │ ✓ Read and write mailbox settings          │
   │ ✓ Read and write user information          │
   │                                             │
   │ [Accept] [Cancel]                          │
   └─────────────────────────────────────────────┘

4. Client clicks "Accept"

5. Microsoft redirects back to your function:
    https://exchange-calendar-processor.mangosmoke-ee55f1a9.australiaeast.azurecontainerapps.io/api/auth/callback
     ?code=<auth-code>
     &state=<client-id>

6. Function exchanges code for tokens:
   POST https://login.microsoftonline.com/<client-tenant-id>/oauth2/v2.0/token
   - Receives: access_token, refresh_token

7. Function stores refresh_token in Key Vault:
   Secret name: "client-<client-id>-exchange-refresh-token"

8. Function redirects client back to Add-In with success message

9. Add-In shows: "✅ Connected to Exchange! You can now sync."
```

### Step 3: Daily Usage (Automatic)

```
User clicks "Trigger Sync Now"
    ↓
Add-In calls: POST /api/sync-to-exchange
    Body: { "apiKey": "<client-api-key>" }
    ↓
Function:
    1. Retrieves client's refresh_token from Key Vault
    2. Gets new access_token from Microsoft (refresh token flow)
    3. Calls Microsoft Graph on behalf of client
    4. Updates mailboxes in CLIENT's Exchange tenant
    5. Returns results to Add-In
```

---

## Implementation Changes

### 1. Create Multi-Tenant Entra App (One-Time Setup)

```bash
# Create multi-tenant app
az ad app create \
  --display-name "FleetBridge SaaS" \
  --sign-in-audience AzureADMultipleOrgs \
    --web-redirect-uris "https://exchange-calendar-processor.mangosmoke-ee55f1a9.australiaeast.azurecontainerapps.io/api/auth/callback"

APP_ID=$(az ad app list --display-name "FleetBridge SaaS" --query "[0].appId" -o tsv)

# Add delegated permissions (USER CONSENT - no admin required!)
az ad app permission add \
  --id $APP_ID \
  --api 00000003-0000-0000-c000-000000000000 \
  --api-permissions \
    1ec239c2-d7c9-4623-a91a-a9775856bb36=Scope \
    6931bccd-447a-43d1-b442-00a195474933=Scope \
    741f803b-c850-494e-b5df-cde7c675a1ca=Scope \
    7427e0e9-2fba-42fe-b0c0-848c9e6a8182=Scope

# Permissions explained:
# 1ec239c2... = Calendars.ReadWrite (Delegated)
# 6931bccd... = MailboxSettings.ReadWrite (Delegated)
# 741f803b... = User.ReadWrite.All (Delegated)
# 7427e0e9... = offline_access (to get refresh tokens)

# Create client secret (for token exchange)
az ad app credential reset \
  --id $APP_ID \
  --append \
  --display-name "FleetBridge Token Exchange"

# Store in Key Vault
az keyvault secret set \
  --vault-name fleetbridge-vault \
  --name "EntraAppClientSecret" \
  --value "<secret-from-above>"
```

**Key Differences from Before:**
- ✅ `--sign-in-audience AzureADMultipleOrgs` (multi-tenant!)
- ✅ **Delegated** permissions (not Application)
- ✅ No admin consent required (users can consent themselves)
- ✅ Client secret instead of certificate (for token exchange)

### 2. Add OAuth Endpoints to Azure Function

```python
# azure-function/function_app_multitenant.py

import msal
from urllib.parse import urlencode, parse_qs
import secrets

# Configuration
ENTRA_CLIENT_ID = os.environ.get('ENTRA_CLIENT_ID')
ENTRA_CLIENT_SECRET_NAME = os.environ.get('ENTRA_CLIENT_SECRET_NAME', 'EntraAppClientSecret')
ENTRA_AUTHORITY = "https://login.microsoftonline.com/organizations"
ENTRA_SCOPES = [
    "https://graph.microsoft.com/Calendars.ReadWrite",
    "https://graph.microsoft.com/MailboxSettings.ReadWrite",
    "https://graph.microsoft.com/User.ReadWrite.All",
    "offline_access"
]

def get_client_secret():
    """Get Entra app client secret from Key Vault."""
    if not key_vault_client:
        raise ValueError("Key Vault not configured")
    
    secret = key_vault_client.get_secret(ENTRA_CLIENT_SECRET_NAME)
    return secret.value


@app.route(route="auth/login", auth_level=func.AuthLevel.ANONYMOUS)
def oauth_login(req: func.HttpRequest) -> func.HttpResponse:
    """
    Step 1: Redirect user to Microsoft consent page.
    
    Query params:
    - clientId: Unique identifier for the client (their database name or API key)
    """
    try:
        client_id = req.params.get('clientId')
        if not client_id:
            return func.HttpResponse("Missing clientId parameter", status_code=400)
        
        # Generate random state to prevent CSRF
        state = secrets.token_urlsafe(32)
        
        # Store state temporarily (could use Redis/Table Storage, for now use in-memory)
        # In production, store in Azure Table Storage with TTL
        # For now, encode client_id in state
        state_with_client = f"{state}:{client_id}"
        
        # Build authorization URL
        redirect_uri = f"https://{os.environ.get('WEBSITE_HOSTNAME', 'localhost:7071')}/api/auth/callback"
        
        auth_params = {
            'client_id': ENTRA_CLIENT_ID,
            'response_type': 'code',
            'redirect_uri': redirect_uri,
            'response_mode': 'query',
            'scope': ' '.join(ENTRA_SCOPES),
            'state': state_with_client,
            'prompt': 'consent'  # Force consent screen every time (optional)
        }
        
        auth_url = f"{ENTRA_AUTHORITY}/oauth2/v2.0/authorize?{urlencode(auth_params)}"
        
        logging.info(f"OAuth login initiated for client: {client_id}")
        
        # Return redirect response
        return func.HttpResponse(
            status_code=302,
            headers={'Location': auth_url}
        )
        
    except Exception as e:
        logging.error(f"OAuth login error: {e}")
        return func.HttpResponse(f"Error: {str(e)}", status_code=500)


@app.route(route="auth/callback", auth_level=func.AuthLevel.ANONYMOUS)
async def oauth_callback(req: func.HttpRequest) -> func.HttpResponse:
    """
    Step 2: Receive auth code from Microsoft and exchange for tokens.
    
    Query params:
    - code: Authorization code from Microsoft
    - state: State parameter (contains client_id)
    - error: Error code (if consent denied)
    """
    try:
        # Check for errors
        error = req.params.get('error')
        if error:
            error_desc = req.params.get('error_description', 'Unknown error')
            logging.error(f"OAuth error: {error} - {error_desc}")
            
            # Return user-friendly error page
            return func.HttpResponse(
                f"""
                <html>
                <body style="font-family: Arial; padding: 40px; text-align: center;">
                    <h1 style="color: #d32f2f;">❌ Connection Failed</h1>
                    <p>{error_desc}</p>
                    <p>Please close this window and try again.</p>
                </body>
                </html>
                """,
                mimetype="text/html",
                status_code=400
            )
        
        # Get authorization code and state
        code = req.params.get('code')
        state = req.params.get('state')
        
        if not code or not state:
            return func.HttpResponse("Missing code or state parameter", status_code=400)
        
        # Extract client_id from state
        try:
            state_nonce, client_id = state.split(':', 1)
        except:
            return func.HttpResponse("Invalid state parameter", status_code=400)
        
        # Exchange code for tokens
        client_secret = get_client_secret()
        redirect_uri = f"https://{os.environ.get('WEBSITE_HOSTNAME')}/api/auth/callback"
        
        msal_app = msal.ConfidentialClientApplication(
            ENTRA_CLIENT_ID,
            authority=ENTRA_AUTHORITY,
            client_credential=client_secret
        )
        
        result = msal_app.acquire_token_by_authorization_code(
            code,
            scopes=ENTRA_SCOPES,
            redirect_uri=redirect_uri
        )
        
        if "error" in result:
            logging.error(f"Token acquisition error: {result.get('error_description')}")
            raise ValueError(result.get('error_description', 'Failed to acquire token'))
        
        # Extract tokens
        access_token = result.get('access_token')
        refresh_token = result.get('refresh_token')
        id_token_claims = result.get('id_token_claims', {})
        tenant_id = id_token_claims.get('tid')
        user_email = id_token_claims.get('preferred_username')
        
        if not refresh_token:
            raise ValueError("No refresh token received (offline_access scope missing?)")
        
        logging.info(f"OAuth tokens received for client: {client_id}, tenant: {tenant_id}")
        
        # Store refresh token in Key Vault
        if key_vault_client:
            secret_name = f"client-{client_id}-exchange-refresh-token"
            key_vault_client.set_secret(secret_name, refresh_token)
            
            # Also store tenant ID (needed for token refresh)
            tenant_secret_name = f"client-{client_id}-exchange-tenant-id"
            key_vault_client.set_secret(tenant_secret_name, tenant_id)
            
            logging.info(f"Stored tokens for client {client_id} in Key Vault")
        
        # Return success page
        return func.HttpResponse(
            f"""
            <html>
            <head>
                <style>
                    body {{
                        font-family: Arial, sans-serif;
                        padding: 40px;
                        text-align: center;
                        background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
                        color: white;
                    }}
                    .container {{
                        background: white;
                        color: #333;
                        padding: 40px;
                        border-radius: 12px;
                        max-width: 600px;
                        margin: 0 auto;
                        box-shadow: 0 10px 40px rgba(0,0,0,0.2);
                    }}
                    h1 {{ color: #10b981; margin-bottom: 20px; }}
                    .info {{ 
                        background: #f3f4f6; 
                        padding: 20px; 
                        border-radius: 8px; 
                        margin: 20px 0;
                        text-align: left;
                    }}
                    .info strong {{ color: #667eea; }}
                    button {{
                        background: #667eea;
                        color: white;
                        border: none;
                        padding: 12px 30px;
                        border-radius: 6px;
                        font-size: 16px;
                        cursor: pointer;
                        margin-top: 20px;
                    }}
                    button:hover {{ background: #5568d3; }}
                </style>
            </head>
            <body>
                <div class="container">
                    <h1>✅ Successfully Connected to Exchange!</h1>
                    <p>FleetBridge can now sync your MyGeotab devices with Exchange Online.</p>
                    
                    <div class="info">
                        <p><strong>Connected as:</strong> {user_email}</p>
                        <p><strong>Organization:</strong> {tenant_id}</p>
                    </div>
                    
                    <p>You can now close this window and return to the MyGeotab Add-In.</p>
                    <button onclick="window.close()">Close Window</button>
                    
                    <script>
                        // Auto-close after 5 seconds
                        setTimeout(() => window.close(), 5000);
                    </script>
                </div>
            </body>
            </html>
            """,
            mimetype="text/html",
            status_code=200
        )
        
    except Exception as e:
        logging.error(f"OAuth callback error: {e}")
        return func.HttpResponse(
            f"""
            <html>
            <body style="font-family: Arial; padding: 40px; text-align: center;">
                <h1 style="color: #d32f2f;">❌ Error</h1>
                <p>{str(e)}</p>
                <p>Please close this window and try again.</p>
            </body>
            </html>
            """,
            mimetype="text/html",
            status_code=500
        )


def get_delegated_graph_token(client_id):
    """
    Get fresh access token for Microsoft Graph using stored refresh token.
    This is called before each sync operation.
    """
    try:
        # Get refresh token and tenant ID from Key Vault
        refresh_token_secret = key_vault_client.get_secret(f"client-{client_id}-exchange-refresh-token")
        tenant_id_secret = key_vault_client.get_secret(f"client-{client_id}-exchange-tenant-id")
        
        refresh_token = refresh_token_secret.value
        tenant_id = tenant_id_secret.value
        
        # Get client secret
        client_secret = get_client_secret()
        
        # Create MSAL app with specific tenant
        authority = f"https://login.microsoftonline.com/{tenant_id}"
        msal_app = msal.ConfidentialClientApplication(
            ENTRA_CLIENT_ID,
            authority=authority,
            client_credential=client_secret
        )
        
        # Acquire token using refresh token
        result = msal_app.acquire_token_by_refresh_token(
            refresh_token,
            scopes=ENTRA_SCOPES
        )
        
        if "error" in result:
            logging.error(f"Token refresh error for client {client_id}: {result.get('error_description')}")
            raise ValueError(f"Failed to refresh token: {result.get('error_description')}")
        
        access_token = result.get('access_token')
        new_refresh_token = result.get('refresh_token')
        
        # Update refresh token if rotated
        if new_refresh_token and new_refresh_token != refresh_token:
            key_vault_client.set_secret(f"client-{client_id}-exchange-refresh-token", new_refresh_token)
            logging.info(f"Updated refresh token for client {client_id}")
        
        return access_token
        
    except Exception as e:
        logging.error(f"Failed to get delegated token for client {client_id}: {e}")
        raise ValueError(f"Exchange connection expired. Please reconnect in the Add-In.")
```

### 3. Update sync-to-exchange to Use Delegated Tokens

```python
@app.route(route="sync-to-exchange", auth_level=func.AuthLevel.FUNCTION)
async def sync_to_exchange(req: func.HttpRequest) -> func.HttpResponse:
    """
    Sync MyGeotab devices to Exchange Online using DELEGATED permissions.
    No certificate needed - uses client's consent tokens.
    """
    start_time = datetime.utcnow()
    logging.info('Sync to Exchange function triggered (delegated mode)')
    
    try:
        req_body = req.get_json()
        
        # Get MyGeotab credentials
        api_key = req_body.get('apiKey')
        database = req_body.get('database')
        username = req_body.get('username')
        password = req_body.get('password')
        max_devices = req_body.get('maxDevices', 0)
        
        credentials = get_client_credentials(api_key, database, username, password)
        
        if not credentials:
            return func.HttpResponse(
                json.dumps({"success": False, "error": "Invalid credentials or API key"}),
                status_code=401,
                mimetype="application/json"
            )
        
        database, username, password = credentials
        equipment_domain = os.environ.get('EQUIPMENT_DOMAIN')
        
        if not equipment_domain:
            return func.HttpResponse(
                json.dumps({"success": False, "error": "EQUIPMENT_DOMAIN not configured"}),
                status_code=500,
                mimetype="application/json"
            )
        
        # Check if client has connected Exchange (has refresh token)
        client_id = api_key if api_key else database
        try:
            access_token = get_delegated_graph_token(client_id)
        except Exception as e:
            return func.HttpResponse(
                json.dumps({
                    "success": False,
                    "error": "Exchange not connected. Please click 'Connect to Exchange' in the Add-In first.",
                    "details": str(e)
                }),
                status_code=401,
                mimetype="application/json"
            )
        
        # Connect to MyGeotab... (rest of sync logic unchanged)
        # But instead of certificate auth, use:
        
        # Create Graph client with delegated token
        from msgraph import GraphServiceClient
        from azure.identity import AccessToken
        from kiota_abstractions.authentication import BaseBearerTokenAuthenticationProvider
        
        class StaticTokenProvider(BaseBearerTokenAuthenticationProvider):
            def __init__(self, token):
                self.token = token
            
            async def get_authorization_token(self, uri, additional_authentication_context=None):
                return self.token
        
        auth_provider = StaticTokenProvider(access_token)
        graph_client = GraphServiceClient(credentials=auth_provider)
        
        # Now use graph_client as before...
        # (rest of sync logic unchanged)
        
    except Exception as e:
        logging.error(f'Error in sync-to-exchange: {str(e)}', exc_info=True)
        # ... error handling
```

---

## Updated index.html (Add-In UI)

```html
<!-- In "Sync to Exchange" tab -->

<section class="properties-section">
    <h2>Exchange Online Connection</h2>
    <p class="info-text">
        Connect FleetBridge to your Microsoft Exchange Online to sync equipment mailboxes.
        This is a one-time setup - you'll be redirected to Microsoft to grant permissions.
    </p>

    <div id="exchangeConnectionStatus" style="padding: 16px; border-radius: 8px; margin-bottom: 20px;">
        <!-- Will be populated by JavaScript -->
    </div>

    <div style="display: flex; gap: 12px;">
        <button id="connectExchangeBtn" class="btn btn-primary">
            <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor">
                <path d="M10 13a5 5 0 0 0 7.54.54l3-3a5 5 0 0 0-7.07-7.07l-1.72 1.71"></path>
            </svg>
            Connect to Exchange
        </button>
        <button id="disconnectExchangeBtn" class="btn btn-secondary" style="display: none;">
            Disconnect
        </button>
    </div>
</section>

<script>
// Check Exchange connection status on load
async function checkExchangeConnection() {
    const clientApiKey = localStorage.getItem('fleetSyncClientApiKey');
    const functionUrl = localStorage.getItem('fleetSyncFunctionUrl');
    const functionKey = localStorage.getItem('fleetSyncFunctionKey');
    
    if (!clientApiKey || !functionUrl || !functionKey) {
        showExchangeStatus('not_configured');
        return;
    }
    
    try {
        // Check if refresh token exists (call a status endpoint)
        const response = await fetch(`${functionUrl}/api/auth/status?code=${functionKey}`, {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ clientId: clientApiKey })
        });
        
        const result = await response.json();
        
        if (result.connected) {
            showExchangeStatus('connected', result);
        } else {
            showExchangeStatus('not_connected');
        }
    } catch (error) {
        showExchangeStatus('error', { error: error.message });
    }
}

function showExchangeStatus(status, data = {}) {
    const statusDiv = document.getElementById('exchangeConnectionStatus');
    const connectBtn = document.getElementById('connectExchangeBtn');
    const disconnectBtn = document.getElementById('disconnectExchangeBtn');
    
    switch(status) {
        case 'connected':
            statusDiv.innerHTML = `
                <div style="background: #d1fae5; border: 1px solid #10b981; color: #065f46; padding: 16px; border-radius: 8px;">
                    <strong>✅ Connected to Exchange</strong><br>
                    <span style="font-size: 13px;">
                        Connected as: ${data.userEmail || 'Unknown'}<br>
                        Organization: ${data.tenantId || 'Unknown'}
                    </span>
                </div>
            `;
            connectBtn.style.display = 'none';
            disconnectBtn.style.display = 'inline-flex';
            break;
            
        case 'not_connected':
            statusDiv.innerHTML = `
                <div style="background: #fef3c7; border: 1px solid #fbbf24; color: #92400e; padding: 16px; border-radius: 8px;">
                    <strong>⚠️ Not Connected to Exchange</strong><br>
                    <span style="font-size: 13px;">
                        Click "Connect to Exchange" to grant FleetBridge access to your Exchange Online.
                    </span>
                </div>
            `;
            connectBtn.style.display = 'inline-flex';
            disconnectBtn.style.display = 'none';
            break;
            
        case 'not_configured':
            statusDiv.innerHTML = `
                <div style="background: #dbeafe; border: 1px solid #3b82f6; color: #1e3a8a; padding: 16px; border-radius: 8px;">
                    <strong>ℹ️ Setup Required</strong><br>
                    <span style="font-size: 13px;">
                        Please configure your Azure Function settings above first.
                    </span>
                </div>
            `;
            connectBtn.disabled = true;
            break;
            
        case 'error':
            statusDiv.innerHTML = `
                <div style="background: #fee2e2; border: 1px solid #ef4444; color: #991b1b; padding: 16px; border-radius: 8px;">
                    <strong>❌ Error</strong><br>
                    <span style="font-size: 13px;">${data.error}</span>
                </div>
            `;
            break;
    }
}

// Connect to Exchange button handler
document.getElementById('connectExchangeBtn').addEventListener('click', async () => {
    const clientApiKey = localStorage.getItem('fleetSyncClientApiKey');
    const functionUrl = localStorage.getItem('fleetSyncFunctionUrl');
    const functionKey = localStorage.getItem('fleetSyncFunctionKey');
    
    if (!clientApiKey || !functionUrl || !functionKey) {
        alert('Please save your Azure Function configuration first.');
        return;
    }
    
    // Open OAuth consent in popup
    const clientId = clientApiKey;
    const authUrl = `${functionUrl}/api/auth/login?clientId=${encodeURIComponent(clientId)}`;
    
    const popup = window.open(
        authUrl,
        'FleetBridge OAuth',
        'width=600,height=800,left=200,top=100'
    );
    
    // Poll for popup close (user completed auth)
    const pollTimer = setInterval(() => {
        if (popup.closed) {
            clearInterval(pollTimer);
            // Recheck connection status
            setTimeout(() => checkExchangeConnection(), 1000);
        }
    }, 500);
});

// Initialize on page load
checkExchangeConnection();
</script>
```

---

## Benefits of This Approach

### 1. **Zero Setup for Clients** ✅
- Install Add-In from MyGeotab store
- Click "Connect to Exchange"
- Grant consent (one-click)
- Done! No Azure portal, no Entra app creation

### 2. **SaaS-Ready** ✅
- Unlimited clients can connect
- All use YOUR single multi-tenant app
- You control the app, updates, permissions

### 3. **Secure** ✅
- Delegated permissions (acts on behalf of signed-in user)
- Tokens stored encrypted in YOUR Key Vault
- Refresh tokens for long-term access (no re-consent)
- Each client's tokens isolated

### 4. **Cost-Effective** ✅
- Only ONE Entra app registration (not per-client)
- No certificates to manage per-client
- Refresh tokens last months/years

### 5. **Better UX** ✅
- Familiar Microsoft consent screen
- Clear permission descriptions
- Users understand what they're granting
- Auto-refresh tokens (no expiry hassles)

---

## Comparison: Application vs Delegated Permissions

| Aspect | Application Permissions (Old) | Delegated Permissions (New) |
|--------|------------------------------|----------------------------|
| **Setup** | Per-client Entra app + cert | One-time consent popup |
| **Admin Consent** | Required (Global Admin) | User consent (any admin) |
| **Access Scope** | All mailboxes in tenant | User's accessible mailboxes |
| **Token Lifetime** | Certificate expiry (2 years) | Refresh token (90 days renewable) |
| **Revocation** | Delete app registration | User revokes in My Apps |
| **Cost** | Per-client certificate mgmt | One app, unlimited clients |
| **SaaS Friendly** | ❌ No | ✅ Yes |

---

## Next Steps

1. **Update Entra app to multi-tenant**
2. **Implement OAuth endpoints** in Azure Function
3. **Update Add-In UI** with "Connect to Exchange" button
4. **Test with 2 different tenants**
5. **Submit to MyGeotab Marketplace**

This is the architecture you need for true SaaS! 🚀
