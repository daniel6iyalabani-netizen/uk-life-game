-- UK Life Game: secure real-player property marketplace
-- Run this file once in Supabase Dashboard > SQL Editor.
create extension if not exists pgcrypto;

create table if not exists public.market_profiles (
  user_id uuid primary key references auth.users(id) on delete cascade,
  display_name text not null default 'New Player' check (char_length(display_name) between 2 and 24),
  role text not null default 'landlord' check (role in ('landlord','estate_agent')),
  wallet_balance integer not null default 2500 check (wallet_balance >= 0),
  created_at timestamptz not null default now()
);

create table if not exists public.market_properties (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null references public.market_profiles(user_id) on delete cascade,
  property_key text not null check (property_key in ('room','studio','flat','maisonette','terraced','semi','house','cottage','townhouse','penthouse')),
  property_name text not null,
  purchase_price integer not null check (purchase_price > 0),
  created_at timestamptz not null default now()
);

create table if not exists public.market_listings (
  id uuid primary key default gen_random_uuid(),
  property_id uuid not null unique references public.market_properties(id) on delete cascade,
  owner_id uuid not null references public.market_profiles(user_id) on delete cascade,
  listing_type text not null check (listing_type in ('rent','sale')),
  price integer not null check (price > 0),
  status text not null default 'active' check (status in ('active','leased')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.market_leases (
  id uuid primary key default gen_random_uuid(),
  listing_id uuid not null references public.market_listings(id) on delete restrict,
  property_id uuid not null references public.market_properties(id) on delete restrict,
  landlord_id uuid not null references public.market_profiles(user_id) on delete restrict,
  tenant_id uuid not null references public.market_profiles(user_id) on delete restrict,
  weekly_rent integer not null check (weekly_rent > 0),
  status text not null default 'active' check (status in ('active','ended')),
  started_at timestamptz not null default now(),
  ended_at timestamptz,
  check (landlord_id <> tenant_id)
);

create index if not exists market_listings_browse_idx on public.market_listings(status, listing_type, created_at desc);
create index if not exists market_leases_tenant_idx on public.market_leases(tenant_id, status);

alter table public.market_profiles enable row level security;
alter table public.market_properties enable row level security;
alter table public.market_listings enable row level security;
alter table public.market_leases enable row level security;

drop policy if exists "Profiles are readable by signed-in players" on public.market_profiles;
create policy "Profiles are readable by signed-in players" on public.market_profiles for select to authenticated using (true);
drop policy if exists "Players can update their own profile name and role" on public.market_profiles;
create policy "Players can update their own profile name and role" on public.market_profiles for update to authenticated using (auth.uid() = user_id) with check (auth.uid() = user_id);
drop policy if exists "Signed-in players can browse properties" on public.market_properties;
create policy "Signed-in players can browse properties" on public.market_properties for select to authenticated using (true);
drop policy if exists "Signed-in players can browse listings" on public.market_listings;
create policy "Signed-in players can browse listings" on public.market_listings for select to authenticated using (true);
drop policy if exists "Players can view leases they are part of" on public.market_leases;
create policy "Players can view leases they are part of" on public.market_leases for select to authenticated using (auth.uid() = tenant_id or auth.uid() = landlord_id);

create or replace function public.market_new_profile()
returns trigger language plpgsql security definer set search_path = public
as $$
begin
  insert into public.market_profiles(user_id, display_name, wallet_balance)
  values (new.id, coalesce(nullif(left(new.raw_user_meta_data->>'display_name',24),''),'Player'), 2500)
  on conflict (user_id) do nothing;
  return new;
end;
$$;
drop trigger if exists on_auth_user_created_market_profile on auth.users;
create trigger on_auth_user_created_market_profile after insert on auth.users for each row execute procedure public.market_new_profile();

create or replace function public.market_set_identity(p_display_name text, p_role text)
returns void language plpgsql security definer set search_path = public
as $$
begin
  if auth.uid() is null then raise exception 'Sign in first'; end if;
  if char_length(trim(p_display_name)) < 2 or char_length(trim(p_display_name)) > 24 then raise exception 'Name must be 2–24 characters'; end if;
  if p_role not in ('landlord','estate_agent') then raise exception 'Choose a valid role'; end if;
  update public.market_profiles set display_name = trim(p_display_name), role = p_role where user_id = auth.uid();
  if not found then raise exception 'Player profile not found'; end if;
end;
$$;

create or replace function public.market_buy_property(p_property_key text)
returns jsonb language plpgsql security definer set search_path = public
as $$
declare v_name text; v_price integer; v_id uuid; v_balance integer;
begin
  if auth.uid() is null then raise exception 'Sign in first'; end if;
  select name, price into v_name, v_price from (values
    ('room','Shared room',500),('studio','Studio flat',1800),('flat','One-bedroom flat',2500),
    ('maisonette','Maisonette',4500),('terraced','Terraced house',6500),('semi','Semi-detached house',12000),
    ('house','Family house',18000),('cottage','Country cottage',22000),('townhouse','Townhouse',35000),
    ('penthouse','City penthouse',65000)
  ) as homes(key,name,price) where key=p_property_key;
  if v_name is null then raise exception 'Invalid property type'; end if;
  select wallet_balance into v_balance from public.market_profiles where user_id=auth.uid() for update;
  if v_balance is null then raise exception 'Player profile not found'; end if;
  if v_balance < v_price then raise exception 'Not enough online marketplace funds. Need £%, have £%',v_price,v_balance; end if;
  update public.market_profiles set wallet_balance=wallet_balance-v_price where user_id=auth.uid();
  insert into public.market_properties(owner_id,property_key,property_name,purchase_price)
  values(auth.uid(),p_property_key,v_name,v_price) returning id into v_id;
  return jsonb_build_object('property_id',v_id,'property_name',v_name,'price',v_price);
end;
$$;

create or replace function public.market_create_listing(p_property_id uuid, p_listing_type text, p_price integer)
returns jsonb language plpgsql security definer set search_path = public
as $$
declare v_prop public.market_properties%rowtype; v_id uuid;
begin
  if auth.uid() is null then raise exception 'Sign in first'; end if;
  if p_listing_type not in ('rent','sale') then raise exception 'Choose rent or sale'; end if;
  if p_price < 1 or p_price > 1000000 then raise exception 'Price must be between £1 and £1,000,000'; end if;
  select * into v_prop from public.market_properties where id=p_property_id and owner_id=auth.uid() for update;
  if not found then raise exception 'You can only list a property you own'; end if;
  if exists(select 1 from public.market_listings where property_id=p_property_id) then raise exception 'This property already has a listing'; end if;
  insert into public.market_listings(property_id,owner_id,listing_type,price)
  values(p_property_id,auth.uid(),p_listing_type,p_price) returning id into v_id;
  return jsonb_build_object('listing_id',v_id);
end;
$$;

create or replace function public.market_remove_listing(p_listing_id uuid)
returns void language plpgsql security definer set search_path = public
as $$
begin
  if auth.uid() is null then raise exception 'Sign in first'; end if;
  delete from public.market_listings where id=p_listing_id and owner_id=auth.uid() and status='active';
  if not found then raise exception 'Listing not found, or it is already rented'; end if;
end;
$$;

create or replace function public.market_transact(p_listing_id uuid)
returns jsonb language plpgsql security definer set search_path = public
as $$
declare v_listing public.market_listings%rowtype; v_prop public.market_properties%rowtype; v_buyer_balance integer; v_name text;
begin
  if auth.uid() is null then raise exception 'Sign in first'; end if;
  select * into v_listing from public.market_listings where id=p_listing_id for update;
  if not found or v_listing.status <> 'active' then raise exception 'This listing is no longer available'; end if;
  if v_listing.owner_id=auth.uid() then raise exception 'You cannot transact with your own listing'; end if;
  select * into v_prop from public.market_properties where id=v_listing.property_id for update;
  if not found or v_prop.owner_id <> v_listing.owner_id then raise exception 'Property ownership could not be verified'; end if;
  select wallet_balance into v_buyer_balance from public.market_profiles where user_id=auth.uid() for update;
  if v_buyer_balance is null or v_buyer_balance < v_listing.price then raise exception 'Not enough online marketplace funds'; end if;
  if v_listing.listing_type='rent' then
    update public.market_profiles set wallet_balance=wallet_balance-v_listing.price where user_id=auth.uid();
    update public.market_profiles set wallet_balance=wallet_balance+v_listing.price where user_id=v_listing.owner_id;
    update public.market_listings set status='leased',updated_at=now() where id=v_listing.id;
    insert into public.market_leases(listing_id,property_id,landlord_id,tenant_id,weekly_rent)
      values(v_listing.id,v_prop.id,v_listing.owner_id,auth.uid(),v_listing.price);
    return jsonb_build_object('type','rent','property_name',v_prop.property_name,'weekly_rent',v_listing.price);
  else
    update public.market_profiles set wallet_balance=wallet_balance-v_listing.price where user_id=auth.uid();
    update public.market_profiles set wallet_balance=wallet_balance+v_listing.price where user_id=v_listing.owner_id;
    update public.market_properties set owner_id=auth.uid() where id=v_prop.id;
    delete from public.market_listings where id=v_listing.id;
    return jsonb_build_object('type','sale','property_name',v_prop.property_name,'price',v_listing.price,'property_id',v_prop.id);
  end if;
end;
$$;

create or replace function public.market_end_lease(p_lease_id uuid)
returns void language plpgsql security definer set search_path = public
as $$
declare v_lease public.market_leases%rowtype;
begin
  if auth.uid() is null then raise exception 'Sign in first'; end if;
  select * into v_lease from public.market_leases where id=p_lease_id for update;
  if not found or v_lease.tenant_id <> auth.uid() or v_lease.status <> 'active' then raise exception 'Active lease not found for this player'; end if;
  update public.market_leases set status='ended',ended_at=now() where id=v_lease.id;
  update public.market_listings set status='active',updated_at=now() where id=v_lease.listing_id and owner_id=v_lease.landlord_id;
end;
$$;

revoke all on function public.market_set_identity(text,text) from public;
revoke all on function public.market_buy_property(text) from public;
revoke all on function public.market_create_listing(uuid,text,integer) from public;
revoke all on function public.market_remove_listing(uuid) from public;
revoke all on function public.market_transact(uuid) from public;
revoke all on function public.market_end_lease(uuid) from public;
grant execute on function public.market_set_identity(text,text) to authenticated;
grant execute on function public.market_buy_property(text) to authenticated;
grant execute on function public.market_create_listing(uuid,text,integer) to authenticated;
grant execute on function public.market_remove_listing(uuid) to authenticated;
grant execute on function public.market_transact(uuid) to authenticated;
grant execute on function public.market_end_lease(uuid) to authenticated;

grant select on public.market_profiles, public.market_properties, public.market_listings, public.market_leases to authenticated;
grant update(display_name,role) on public.market_profiles to authenticated;
