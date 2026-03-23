# Stripe Connect Setup Guide

## Overview
This guide explains how to set up Stripe Connect for the Beatelion platform, enabling producers to receive direct payments to their Stripe accounts.

## What Was Added

### Database Changes
- **Migration**: `20260324000000_201_add_stripe_connect_columns.sql`
  - Added columns to `user_profiles`:
    - `stripe_account_id`: Stripe Connect account ID
    - `stripe_account_charges_enabled`: Whether account can receive charges
    - `stripe_account_details_submitted`: Whether onboarding details submitted
    - `stripe_account_created_at`: Account creation timestamp
  - Creates index on `stripe_account_id` for performance

### Edge Functions

#### 1. `stripe-connect-onboarding`
- **Purpose**: Manages Stripe Connect account creation and onboarding flow
- **Endpoints**:
  - `action: "create_account_link"` - Creates/resumes account link for onboarding
  - `action: "get_status"` - Returns current onboarding status
- **Authentication**: JWT bearer token required
- **Returns**: Onboarding URL for Stripe hosted form

#### 2. `stripe-connect-webhook`
- **Purpose**: Handles Stripe webhook events for account status updates
- **Events Handled**:
  - `account.updated` - Updates `charges_enabled` and `details_submitted` flags
- **Webhook Endpoint**: `/functions/v1/stripe-connect-webhook`

### Frontend Pages
- **`ProducerStripeConnect.tsx`**: UI for producers to manage Stripe Connect onboarding
  - Shows account status (created, details submitted, charges enabled)
  - Provides next steps based on current status
  - Refresh button to check latest status

## Installation Steps

### 1. Run Database Migrations
```bash
# Apply the migration to add Stripe Connect columns
supabase migration up
```

### 2. Deploy Edge Functions
```bash
# Deploy the onboarding function
supabase functions deploy stripe-connect-onboarding

# Deploy the webhook function
supabase functions deploy stripe-connect-webhook
```

### 3. Configure Stripe Webhook
In your Stripe Dashboard:
1. Go to Developers → Webhooks
2. Create new endpoint with URL: `https://your-project.supabase.co/functions/v1/stripe-connect-webhook`
3. Select events: `account.updated`
4. Copy webhook secret and add to environment variables: `STRIPE_WEBHOOK_SECRET_CONNECT`

### 4. Add Environment Variables
Add to Supabase Edge Functions environment:
```
STRIPE_SECRET_KEY=sk_...
STRIPE_WEBHOOK_SECRET_CONNECT=whsec_...
ENVIRONMENT=production|staging|development
```

### 5. Add Route to Frontend Router
```typescript
// In your router configuration
import { ProducerStripeConnectPage } from './pages/ProducerStripeConnect';

{
  path: '/producer/stripe-connect',
  element: <ProducerStripeConnectPage />,
  requireAuth: true,
}
```

### 6. Add Navigation Link
Add link in producer settings/dashboard:
```typescript
<Link to="/producer/stripe-connect">
  Manage Stripe Connect
</Link>
```

## How It Works

### Producer Onboarding Flow
1. Producer visits `/producer/stripe-connect` page
2. Clicks "Create Stripe Connect Account"
3. System creates Express account in Stripe
4. User is redirected to Stripe-hosted onboarding form
5. Producer completes KYC and bank details
6. Stripe sends webhook with account status
7. Database is updated with `charges_enabled` flag

### Payment Flow with Stripe Connect
When a customer purchases a beat:
1. Checkout creates session with Connect transfer parameters
2. Stripe processes payment
3. Platform fee is deducted (configurable)
4. Remaining amount is transferred to producer's Stripe account
5. Producer sees earnings in their Stripe Dashboard
6. Weekly payouts to producer's bank account

### Fallback Behavior
- If producer hasn't enabled Stripe Connect, simple Stripe checkout is used
- Platform retains all payments
- Producer receives credit allocation instead
- No blocking of transactions

## Testing

### Local Testing
```bash
# Use Stripe test accounts
STRIPE_SECRET_KEY=sk_test_...

# Test webhook locally with Stripe CLI
stripe listen --forward-to localhost:3000/functions/v1/stripe-connect-webhook
```

### Test Account Creation
1. Create test Stripe Connect account in test mode
2. Verify columns are populated in user_profiles
3. Check webhook triggers when you update test account in Stripe Dashboard

## Monitoring

### Key Metrics to Track
- Number of producers with Stripe Connect enabled
- Number of successful transfers
- Transfer amounts over time
- Webhook delivery success rate

### Logs
Check Supabase Edge Functions logs for:
- `[stripe-connect-onboarding]` - Account creation and link generation
- `[stripe-connect-webhook]` - Webhook processing and status updates

## Troubleshooting

### Producer sees "User is not a producer"
- Check `user_profiles.is_producer_active` is true
- May need to activate producer status first

### Charges enabled flag not updating
- Verify webhook endpoint is configured correctly
- Check webhook secret is correct in environment
- Review Stripe Dashboard for failed webhook deliveries

### Account link returns error
- Ensure Stripe API key has correct permissions
- Check account is in correct state for onboarding
- Verify return_url and refresh_url are valid

## Future Enhancements
- [ ] Dashboard widget showing transfer history
- [ ] Payout schedule information
- [ ] Support for custom platform fee percentages
- [ ] Advanced onboarding with pre-filled details
- [ ] Email notifications when payouts occur
