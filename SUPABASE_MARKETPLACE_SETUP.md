# UK Life Game — real-player property marketplace setup

The phone's **Homes** app contains the real-player marketplace UI. It uses Supabase anonymous sign-in so players can choose a game-only nickname without entering an email address or password. Listings and purchases are shared through the database.

## Make it live

1. Create a project at https://supabase.com/ and wait for it to finish provisioning.
2. In the Supabase dashboard, open **SQL Editor**, create a query, paste the entire contents of `supabase-marketplace-setup.sql`, and run it.
3. In **Project Settings → API** (or **Connect**, depending on the dashboard layout), copy the **Project URL** and the **publishable key**. The legacy `anon` key is also intended for browser clients.
4. Open the published game, open the phone, choose **Homes**, expand **Connect online marketplace**, paste the URL and key, and press **Connect**.
5. In the Supabase dashboard, open **Authentication → Sign In / Providers** (the label may vary) and enable **Anonymous Sign-Ins**. The game’s **Play with nickname** button then creates a game-only online player without an email or password. Each browser keeps its own signed-in session; clearing browser data may lose access to that anonymous player identity.
6. Players can buy a property using their online marketplace balance, publish it for rent or sale, and other players can transact with that listing. The database verifies listing ownership and handles the balance transfer server-side.

## Security notes

- **Never put a Supabase `service_role` key or any secret key in the game.** Only use the browser-safe publishable/`anon` key.
- Row-level security is enabled in the SQL setup. Marketplace transactions are implemented as database functions so players cannot simply update another player's balance or property through ordinary table writes.
- Enable **Anonymous Sign-Ins** for nickname-only accounts. Anonymous identities are tied to their browser session and are not recoverable like email-backed accounts; do not spend anything you would be upset to lose until you understand this limitation. Review authentication settings before sharing the game widely.

## Current limitations

- The online marketplace has its own server-side balance, initially **£2,500 per account**. It is intentionally separate from the offline/local game cash because browser-local money cannot be securely trusted as a multiplayer payment source.
- Properties already owned in a player's offline save are not automatically imported. Properties must be purchased in the online marketplace before they can be listed.
- A player-to-player rental charges the first week's rent and marks the listing as leased. Weekly recurring rent collection, deposit disputes, lease expiry, and estate-agent commission are not automated yet.
- Supabase must be configured by the project owner before any real-player listings can go live. Until then, the existing NPC listings still work.
