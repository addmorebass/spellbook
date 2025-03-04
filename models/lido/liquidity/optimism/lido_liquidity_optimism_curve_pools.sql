{{ config(
    schema='lido_liquidity_optimism',
    alias = alias('curve_pools'),
    tags = ['dunesql'], 
    partition_by = ['time'],
    materialized = 'table',
    file_format = 'delta',
    unique_key = ['pool', 'time'],
    post_hook='{{ expose_spells(\'["optimism"]\',
                                "project",
                                "lido_liquidity",
                                \'["ppclunghe", "kemasan"]\') }}'
    )
}}

{% set project_start_date = '2022-10-06' %}

with dates as (
    with day_seq as (select (sequence(cast('{{ project_start_date }}' as date), current_date, interval '1' day)) as day)
select days.day
from day_seq
cross join unnest(day) as days(day)
  )


, weth_prices_daily AS (
    SELECT distinct
        DATE_TRUNC('day', minute) AS time,
        contract_address as token,
        symbol,
        decimals,
        avg(price) AS price
    FROM {{source('prices','usd')}}
    WHERE date_trunc('day', minute) >= date '{{ project_start_date }}' 
    and date_trunc('day', minute) < current_date
    and blockchain = 'optimism'
    and contract_address = 0x4200000000000000000000000000000000000006
    group by 1,2,3,4
    union all
    SELECT distinct
        DATE_TRUNC('day', minute), 
        contract_address as token,
        symbol,
        decimals,
        last_value(price) over (partition by DATE_TRUNC('day', minute), contract_address ORDER BY  minute range between unbounded preceding AND unbounded following) AS price
    FROM {{source('prices','usd')}}
    WHERE date_trunc('day', minute) = current_date
    and blockchain = 'optimism'
    and contract_address = 0x4200000000000000000000000000000000000006

    
)    

, weth_prices_hourly AS (
    select time
    , lead(time,1, DATE_TRUNC('hour', now() + interval '1' hour)) over (order by time) as next_time
    , price
    from (
    SELECT distinct
        DATE_TRUNC('hour', minute) time
        , last_value(price) over (partition by DATE_TRUNC('hour', minute), contract_address ORDER BY  minute range between unbounded preceding AND unbounded following) AS price
    FROM {{ source('prices', 'usd') }}
    WHERE date_trunc('hour', minute) >=date'{{ project_start_date }}' 
    and blockchain = 'optimism'
    and contract_address = 0x4200000000000000000000000000000000000006
    
))   

, wsteth_prices_daily AS (
    SELECT distinct
        DATE_TRUNC('day', minute) AS time,
        contract_address as token,
        symbol,
        decimals,
        avg(price) AS price
    FROM {{source('prices','usd')}}
    WHERE date_trunc('day', minute) >= date '{{ project_start_date }}' 
    and date_trunc('day', minute) < date_trunc('day', now())
    and blockchain = 'ethereum'
    and contract_address = 0x7f39c581f595b53c5cb19bd0b3f8da6c935e2ca0
    group by 1,2,3,4
    union all
    SELECT distinct
        DATE_TRUNC('day', minute), 
        contract_address as token,
        symbol,
        decimals,
        last_value(price) over (partition by DATE_TRUNC('day', minute), contract_address ORDER BY  minute range between unbounded preceding AND unbounded following) AS price
    FROM {{source('prices','usd')}}
    WHERE date_trunc('day', minute) = date_trunc('day', now())
    and blockchain = 'ethereum'
    and contract_address = 0x7f39c581f595b53c5cb19bd0b3f8da6c935e2ca0

)

, add_liquidity_events as (
    select  date_trunc('day', evt_block_time) as time
        , contract_address as pool
        , sum(cast(token_amounts[1] as double)) as eth_amount_raw
        , sum(cast(token_amounts[2] as double)) as wsteth_amount_raw
    from {{source('curvefi_optimism','wstETH_swap_evt_AddLiquidity')}}
    WHERE date_trunc('day', evt_block_time) >= date '{{ project_start_date }}'
    group by 1, 2
) 

, remove_liquidity_events as (
    select time, pool, sum(eth_amount_raw) as eth_amount_raw, sum(wsteth_amount_raw) as wsteth_amount_raw
    from (
    select date_trunc('day', evt_block_time) as time
        , contract_address as pool
        , double '0' as eth_amount_raw
        , cast(coin_amount as double) as wsteth_amount_raw
    from {{source('curvefi_optimism','wstETH_swap_evt_RemoveLiquidityOne')}}
    WHERE date_trunc('day', evt_block_time) >= date'{{ project_start_date }}'
    and evt_tx_hash in (select evt_tx_hash from {{source('lido_optimism','wstETH_evt_Transfer')}})
    
    union all
    
    select date_trunc('day', evt_block_time) as time
        , contract_address as pool
        , cast(coin_amount as double) as eth_amount_raw
        , double '0' as wsteth_amount_raw
    from {{source('curvefi_optimism','wstETH_swap_evt_RemoveLiquidityOne')}}
    WHERE date_trunc('day', evt_block_time) >= date '{{ project_start_date }}'
    and evt_tx_hash not in (select evt_tx_hash from {{source('lido_optimism','wstETH_evt_Transfer')}})
    
    union all
    
    select  date_trunc('day', evt_block_time) as time
        , contract_address as pool
        , cast(token_amounts[1] as double)
        , cast(token_amounts[2] as double)
    from {{source('curvefi_optimism','wstETH_swap_evt_RemoveLiquidityImbalance')}}
    WHERE date_trunc('day', evt_block_time) >= date'{{ project_start_date }}'
    
    union all
    
    select date_trunc('day', evt_block_time) as time
        , contract_address as pool
        , cast(token_amounts[1] as double)
        , cast(token_amounts[2] as double)
    from {{source('curvefi_optimism','wstETH_swap_evt_RemoveLiquidity')}}
    WHERE date_trunc('day', evt_block_time) >= date'{{ project_start_date }}'

) group by 1,2
)

, token_exchange_events as(
    select date_trunc('day', evt_block_time) as time
        , contract_address as pool
        , sum(case when cast(sold_id as double) = double '0'
            then cast(tokens_sold as double) else (-1) * cast(tokens_bought as double) end) as eth_amount_raw
        , sum(case when cast(sold_id as double) = double '0'
            then (-1) * cast(tokens_bought as double) else cast(tokens_sold as double) end) as wsteth_amount_raw
    from {{source('curvefi_optimism','wstETH_swap_evt_TokenExchange')}}
    WHERE date_trunc('day', evt_block_time) >= date '{{ project_start_date }}'
    group by 1,2
)

, reserves as (
    select day
        , coalesce(d.pool, w.pool, e.pool, 0xb90b9b1f91a01ea22a182cd84c1e22222e39b415) as pool
        , case when p2.token = 0x7f39c581f595b53c5cb19bd0b3f8da6c935e2ca0 then 0x1F32b1c2345538c0c6f582fCB022739c4A194Ebb end as main_token
        , p2.symbol as main_token_symbol
        , p1.token as paired_token
        , p1.symbol as paired_token_symbol 
        , (sum(coalesce(d.wsteth_amount_raw, 0) - coalesce(w.wsteth_amount_raw, 0) + coalesce(e.wsteth_amount_raw, 0)) over (order by dd.day))/1e18 as main_token_reserve
        , ((sum(coalesce(d.wsteth_amount_raw, 0) - coalesce(w.wsteth_amount_raw, 0) + coalesce(e.wsteth_amount_raw, 0)) over (order by dd.day))* p2.price)/1e18 as main_token_usd_reserve
        , (sum(coalesce(d.eth_amount_raw, 0) - coalesce(w.eth_amount_raw, 0) + coalesce(e.eth_amount_raw, 0)) over (order by dd.day))/1e18 as paired_token_reserve
        , ((sum(coalesce(d.eth_amount_raw, 0) - coalesce(w.eth_amount_raw, 0) + coalesce(e.eth_amount_raw, 0)) over (order by dd.day)) * p1.price) /1e18 as paired_token_usd_reserve
    from dates dd  
    left join add_liquidity_events d on dd.day = d.time
    left join remove_liquidity_events w on dd.day = w.time
    left join token_exchange_events e on dd.day = e.time
    left join weth_prices_daily p1 ON p1.time = dd.day 
    left join wsteth_prices_daily p2 ON p2.time = dd.day
    order by dd.day desc
)

, token_exchange_hourly as( 
    select date_trunc('hour', evt_block_time) as time
        , sum(case when cast(sold_id as double) = 0 
            then cast(tokens_sold as double) else cast(tokens_bought as double) end) as eth_amount_raw
    from {{source('curvefi_optimism','wstETH_swap_evt_TokenExchange')}}
    WHERE date_trunc('day', evt_block_time) >= date '{{ project_start_date }}'
    group by 1   
)

, trading_volume_hourly as (
    select t.time
        , t.eth_amount_raw * wp.price as volume_raw 
    from token_exchange_hourly t
    left join weth_prices_hourly wp on t.time = wp.time
    order by 1
)

, trading_volume as ( 
    select distinct date_trunc('day', time) as time
        , sum(volume_raw)/1e18 as volume
    from trading_volume_hourly 
    GROUP by 1
)


, all_metrics as (
    select  
        pool 
        , 'optimism' as blockchain
        , 'curve' as project
        , 0.04 as fee
        , cast(day as date) as time
        , main_token
        , main_token_symbol
        , paired_token
        , paired_token_symbol
        , main_token_reserve 
        , paired_token_reserve
        , main_token_usd_reserve
        , paired_token_usd_reserve
        , coalesce(volume,0) as trading_volume 
    from reserves r
    left join trading_volume ON r.day = trading_volume.time
    order by day desc
)


select CONCAT(CONCAT(CONCAT(CONCAT(CONCAT(blockchain,CONCAT(' ', project)) ,' '), coalesce(paired_token_symbol,'unknown')),':') , main_token_symbol, ' ',  format('%,.3f%%',round(coalesce(fee,0),4))) as pool_name,* 
from all_metrics

