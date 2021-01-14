-- :hotspot_list_base
select 
    (select max(height) from blocks) as height,
    g.last_block, 
    g.first_block, 
    g.first_timestamp, 
    g.last_poc_challenge,
    g.address,
    g.owner, 
    g.location, 
    g.nonce, 
    g.name,
    s.online as online_status, 
    s.block as block_status,
    s.listen_addrs as listen_addrs,
    l.short_street, l.long_street,
    l.short_city, l.long_city,
    l.short_state, l.long_state,
    l.short_country, l.long_country,
    l.city_id
    :source
left join locations l on g.location = l.location
left join gateway_status s on s.address = g.address
:scope
:order
:limit 

-- :hotspot_list_order
order by g.first_block desc, g.address

-- :hotspot_list_source
from gateway_inventory g

-- :hotspot_list_before_scope
where ((g.address > $1 and g.first_block = $2) or (g.first_block < $2))

-- :owner_hotspot_list_source
from (select * from gateway_inventory where owner = $1) as g

-- :owner_hotspot_list_before_scope
where ((g.address > $2 and g.first_block = $3) or (g.first_block < $3))

-- :city_hotspot_list_before_scope
where l.city_id = $1
and ((g.address > $2 and g.first_block = $3) or (g.first_block < $3))

-- :city_hotspot_list_before_scope
where l.city_id = $1
and ((g.address > $2 and g.first_block = $3) or (g.first_block < $3))

-- :city_hotspot_list_scope
where l.city_id = $1

-- :hotspot_witness_list
with min as (
    select height from blocks where timestamp > (now() - '5 day'::interval) order by height limit 1
),
recent_witnesses as (
     select $1 as address, jsonb_merge_agg(witnesses) as witnesses from 
        (select * 
        from gateways 
        where address = $1 and block >= (select height from min) 
        order by block) a
 ),
hotspot_witnesses as (
    select r.address as witness_for, w.key as witness, w.value as witness_info
    from recent_witnesses r, jsonb_each(r.witnesses) w
)
:hotspot_select

-- :hotspot_witness_list_source
, g.witness_for, g.witness_info
from (select * from hotspot_witnesses w inner join gateway_inventory i on (w.witness = i.address)) g

-- :hotspot_elected_list
with field_members as (
    select fields->'members' as members
    from transactions
    where type = 'consensus_group_v1' :filter
    order by block desc 
    limit 1
),
members as (
    select * 
    from jsonb_array_elements_text((select members from field_members))
)
:hotspot_select

-- :hotspot_elected_list_scope
where g.address in (select * from members)

