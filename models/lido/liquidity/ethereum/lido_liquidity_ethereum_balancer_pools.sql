{{ config(
    alias = alias('balancer_pools'),
    tags = ['dunesql'], 
    partition_by = ['time'],
    materialized = 'table',
    file_format = 'delta',
    unique_key = ['pool', 'time'],
    post_hook='{{ expose_spells(\'["ethereum"]\',
                                "project",
                                "lido_liquidity",
                                \'["ppclunghe"]\') }}'
    )
}}

{% set project_start_date = '2021-08-13' %} 


with dates as (
    with day_seq as (select (sequence(cast('{{ project_start_date }}' as date), current_date, interval '1' day)) as day)
select days.day
from day_seq
cross join unnest(day) as days(day)
)

, pools(pool_id, poolAddress) as (
values       
(0x32296969EF14EB0C6D29669C550D4A0449130230000200000000000000000080, 0x32296969ef14eb0c6d29669c550d4a0449130230), 
(0x5AEE1E99FE86960377DE9F88689616916D5DCABE000000000000000000000467, 0x5AEE1E99FE86960377DE9F88689616916D5DCABE),
(0x9C6D47FF73E0F5E51BE5FD53236E3F595C5793F200020000000000000000042C, 0x9C6D47FF73E0F5E51BE5FD53236E3F595C5793F2),
(0xE0FCBF4D98F0AD982DB260F86CF28B49845403C5000000000000000000000504, 0xE0FCBF4D98F0AD982DB260F86CF28B49845403C5),
(0x5F1F4E50BA51D723F12385A8A9606AFC3A0555F5000200000000000000000465, 0x5F1F4E50BA51D723F12385A8A9606AFC3A0555F5),
(0x25ACCB7943FD73DDA5E23BA6329085A3C24BFB6A000200000000000000000387, 0x25ACCB7943FD73DDA5E23BA6329085A3C24BFB6A)
              
)

, pool_per_date as ( 
select dates.day, pools.*
from dates
left join pools on 1=1
)


, tokens as (
select distinct token_address from (
SELECT  tokens.token_address
FROM {{source('balancer_v2_ethereum','WeightedPoolV2Factory_call_create')}} call_create
    CROSS JOIN UNNEST(call_create.tokens) as tokens(token_address)
WHERE call_create.output_0 in (select distinct  poolAddress from pools)
union all
SELECT tokens.token_address
FROM {{source('balancer_v2_ethereum','WeightedPool2TokensFactory_call_create')}} call_create
    CROSS JOIN UNNEST(call_create.tokens) as tokens(token_address)
WHERE call_create.output_0 in (select distinct  poolAddress from pools)
union all
SELECT tokens.token_address
FROM {{source('balancer_v2_ethereum','WeightedPoolFactory_call_create')}} call_create
    CROSS JOIN UNNEST(call_create.tokens) as tokens(token_address)
WHERE call_create.output_0 in (select distinct  poolAddress from pools)
union all
SELECT tokens.token_address
FROM {{source('balancer_v2_ethereum','StablePoolFactory_call_create')}} call_create
    CROSS JOIN UNNEST(call_create.tokens) as tokens(token_address)
WHERE call_create.output_0 in (select distinct  poolAddress from pools)
union all
SELECT tokens.token_address
FROM {{source('balancer_v2_ethereum','MetaStablePoolFactory_call_create')}} call_create
    CROSS JOIN UNNEST(call_create.tokens) as tokens(token_address)
WHERE call_create.output_0 in (select distinct  poolAddress from pools)
union all
SELECT tokens.token_address
FROM {{source('balancer_v2_ethereum','ComposableStablePoolFactory_call_create')}} call_create
    CROSS JOIN UNNEST(call_create.tokens) as tokens(token_address)
WHERE call_create.output_0 in (select distinct  poolAddress from pools)
)
)

,  sfrxeth_rate as (
select time, lead(time, 1 , date_trunc('hour', now()) + interval '1' hour) over (order by time) as next_time, rate
from (
    select 
        date_trunc('hour', call_block_time) as time, 
        avg(CAST(output_0 AS DOUBLE))/POW(10,18) as rate
    from {{source('frax_ethereum','sfrxETH_call_pricePerShare')}}
    WHERE call_success
    AND call_block_time >= date '{{ project_start_date }}'
    GROUP BY 1)
    order by 1 desc
)

    

, tokens_prices_daily AS (
    SELECT distinct
        DATE_TRUNC('day', minute) AS time,
        contract_address as token,
        symbol,
        decimals,
        avg(price) AS price
    FROM {{source('prices','usd')}}
    WHERE date_trunc('day', minute) >= date '{{ project_start_date }}' 
    and date_trunc('day', minute) < current_date
    and blockchain = 'ethereum'
    and contract_address in (select distinct token_address from tokens)
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
    and blockchain = 'ethereum'
    and contract_address in (select distinct token_address from tokens)
    union all
    SELECT distinct
        DATE_TRUNC('day', minute) AS time,
        0x60D604890feaa0b5460B28A424407c24fe89374a as token,
        'bb-a-WETH',
        18,
        avg(price) AS price
    FROM {{source('prices','usd')}}
    WHERE date_trunc('day', minute) >= date '{{ project_start_date }}' 
    and date_trunc('day', minute) < current_date
    and blockchain = 'ethereum'
    and contract_address = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2
    group by 1,2,3,4

union all
    SELECT distinct
        DATE_TRUNC('day', minute), 
        0x60D604890feaa0b5460B28A424407c24fe89374a as token,
        'bb-a-WETH',
        18,
        last_value(price) over (partition by DATE_TRUNC('day', minute), contract_address ORDER BY  minute range between unbounded preceding AND unbounded following) AS price
    FROM {{source('prices','usd')}}
    WHERE date_trunc('day', minute) = current_date
    and blockchain = 'ethereum'
    and contract_address = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2
union all
SELECT distinct
        DATE_TRUNC('day', minute) AS time,
        0xac3e018457b222d93114458476f3e3416abbe38f as token,
        'sfrxETH',
        18,
        avg(price*r.rate) AS price
    FROM {{source('prices','usd')}} p
    left join sfrxeth_rate r on DATE_TRUNC('day', minute) >= r.time and DATE_TRUNC('day', minute) < r.next_time 
    WHERE date_trunc('day', minute) >= date '{{ project_start_date }}'
    and blockchain = 'ethereum'
     and contract_address = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2
    group by 1,2,3,4
union all
SELECT distinct
        DATE_TRUNC('day', minute) AS time,
        0xa13a9247ea42d743238089903570127dda72fe44 as token,
        'bb-a-USD',
        18,
        avg(price) AS price
    FROM {{source('prices','usd')}} p
    WHERE date_trunc('day', minute) >= date '{{ project_start_date }}'
    and blockchain = 'ethereum'
     and contract_address = 0xdac17f958d2ee523a2206206994597c13d831ec7
    group by 1,2,3,4
    
    
)

, wsteth_prices_hourly AS (
    select time, lead(time,1, DATE_TRUNC('hour', now() + interval '1' hour)) over (order by time) as next_time, price
    from (
    SELECT distinct
        DATE_TRUNC('hour', minute) time,
        last_value(price) over (partition by DATE_TRUNC('hour', minute), contract_address ORDER BY  minute range between unbounded preceding AND unbounded following) AS price
    FROM {{source('prices','usd')}}
    WHERE date_trunc('day', minute) >= date '{{ project_start_date }}'
    and blockchain = 'ethereum'
    and contract_address = 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0
)
)


, swaps_changes as (
        SELECT
            day,
            pool_id,
            token,
            SUM(COALESCE(delta, 0)) AS delta
        FROM
            (
                SELECT
                    date_trunc('day', evt_block_time) AS day,
                    poolId AS pool_id,
                    tokenIn AS token,
                    cast(amountIn as double) AS delta
                FROM {{source('balancer_v2_ethereum','Vault_evt_Swap')}}
                WHERE date_trunc('day', evt_block_time) >= date '{{ project_start_date }}'
                and poolId in (select pool_id from pools)
                UNION
                ALL
                SELECT
                    date_trunc('day', evt_block_time) AS day,
                    poolId AS pool_id,
                    tokenOut AS token,
                    -cast(amountOut as double) AS delta
                FROM {{source('balancer_v2_ethereum','Vault_evt_Swap')}}
                WHERE date_trunc('day', evt_block_time) >= date '{{ project_start_date }}'
                and poolId in (select pool_id from pools)
            ) swaps
        GROUP BY 1, 2, 3
)


, balances_changes AS (
        SELECT
            date_trunc('day', evt_block_time) AS day,
            poolId AS pool_id,
            u.token,
            cast(u.delta as double) as delta
        FROM {{source('balancer_v2_ethereum','Vault_evt_PoolBalanceChanged')}}
         CROSS JOIN UNNEST(tokens, deltas) as u(token, delta)
        WHERE date_trunc('day', evt_block_time) >= date '{{ project_start_date }}'
        and poolId in (select pool_id from pools)
        ORDER BY 1, 2, 3
    )

, managed_changes AS (
        SELECT
            date_trunc('day', evt_block_time) AS day,
            poolId AS pool_id,
            token,
            cast(managedDelta as double) AS delta
        FROM {{source('balancer_v2_ethereum','Vault_evt_PoolBalanceManaged')}}
        WHERE date_trunc('day', evt_block_time) >= date '{{ project_start_date }}'
        and poolId in (select pool_id from pools)
)

, daily_delta_balance AS (
        SELECT
            day,
            pool_id,
            token,
            SUM(COALESCE(amount, 0)) AS amount
        FROM
            (
                SELECT
                    day,
                    pool_id,
                    token,
                    SUM(COALESCE(delta, 0)) AS amount
                FROM
                    balances_changes
                GROUP BY 1, 2, 3
                UNION ALL
                SELECT
                    day,
                    pool_id,
                    token,
                    delta AS amount
                FROM
                    swaps_changes
                UNION ALL
                SELECT
                    day,
                    pool_id,
                    token,
                    delta AS amount
                FROM
                    managed_changes
            ) balance
        GROUP BY 1, 2, 3
)

, cumulative_balance AS (
        SELECT
            DAY,
            pool_id,
            token,
            LEAD(DAY, 1, NOW()) OVER (PARTITION BY token, pool_id ORDER BY DAY) AS day_of_next_change,
            SUM(amount) OVER (PARTITION BY pool_id, token ORDER BY DAY ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS cumulative_amount
        FROM daily_delta_balance
)

, cumulative_usd_balance AS (
        SELECT
            c.day,
            c.pool_id,
            b.token,
            p1.symbol AS token_symbol,
            cumulative_amount as token_balance_raw,
            cumulative_amount / POWER(10, p1.decimals) AS token_balance,
            cumulative_amount / POWER(10, p1.decimals) * COALESCE(p1.price, 0) AS amount_usd, 
            0 as row_numb
        FROM pool_per_date c
        LEFT JOIN cumulative_balance b ON b.day <= c.day AND c.day < b.day_of_next_change and c.pool_id = b.pool_id
        
        LEFT JOIN tokens_prices_daily p1 ON p1.time = b.day AND p1.token = b.token
        WHERE b.token = 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0
        union all
               SELECT
            c.day,
            c.pool_id,
            b.token,
            p1.symbol AS token_symbol,
            cumulative_amount as token_balance_raw,
            cumulative_amount / POWER(10, p1.decimals) AS token_balance,
            cumulative_amount / POWER(10, p1.decimals) * COALESCE(p1.price, 0) AS amount_usd, 
            row_number() OVER(PARTITION BY c.day,c.pool_id ORDER BY  c.day,c.pool_id, b.token) as row_numb
        FROM pool_per_date c
        LEFT JOIN cumulative_balance b ON b.day <= c.day AND c.day < b.day_of_next_change and c.pool_id = b.pool_id
        LEFT JOIN tokens_prices_daily p1 ON p1.time = b.day AND p1.token = b.token
        WHERE b.token not in (select poolAddress from pools
                              union all
                              select 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0 )
)

, reserves as (
select main.day, main.pool_id, 
main_token, main_token_symbol, main_token_reserve, main_token_usd_reserve,
paired1_token, paired1_token_symbol, paired1_token_reserve, paired1_token_usd_reserve,
paired2_token, paired2_token_symbol, paired2_token_reserve, paired2_token_usd_reserve
from (
SELECT
    b.day,
    b.pool_id,
    token AS main_token,
    token_symbol as main_token_symbol,
    coalesce(token_balance, token_balance_raw) as main_token_reserve,
    coalesce(amount_usd, 0) AS main_token_usd_reserve
FROM cumulative_usd_balance b
where token = 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0 ) main
join 
(
SELECT
    b.day,
    b.pool_id,
    token AS paired1_token,
    token_symbol as paired1_token_symbol,
    coalesce(token_balance, token_balance_raw) as paired1_token_reserve,
    coalesce(amount_usd, 0) AS paired1_token_usd_reserve
FROM cumulative_usd_balance b
where token !=  0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0 and cast(row_numb as int) = int '1') paired1
on main.day = paired1.day and main.pool_id = paired1.pool_id 
left join (
SELECT
    b.day,
    b.pool_id,
    token AS paired2_token,
    token_symbol as paired2_token_symbol,
    coalesce(token_balance, token_balance_raw) as paired2_token_reserve,
    coalesce(amount_usd, 0) AS paired2_token_usd_reserve
FROM cumulative_usd_balance b
where token !=  0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0 and cast(row_numb as int) = int '2') paired2
on main.day = paired2.day and main.pool_id = paired2.pool_id 
)

, trading_volume as (    
    select  date_trunc('day', s.evt_block_time) as time,
        poolId,
        sum(
        case when tokenOut = 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0 then wsteth_price.price*amountOut/1e18 
             when tokenIn = 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0 then  wsteth_price.price*amountIn/1e18 
             else 0 end) as trading_volume
    from {{source('balancer_v2_ethereum','Vault_evt_Swap')}} s
    left join wsteth_prices_hourly wsteth_price on date_trunc('hour', s.evt_block_time) >= wsteth_price.time and date_trunc('hour', s.evt_block_time) < wsteth_price.next_time
    where s.evt_block_time >= date '{{ project_start_date }}'
      and s.poolId in (select pool_id from pools)
    group by 1,2
) 

, all_metrics as (
select  pool_id as pool, 'ethereum' as blockchain, 'balancer' as project, 0 as fee, 
cast(day as date) as time, main_token, main_token_symbol, 
paired1_token as paired_token,
paired1_token_symbol||case when paired2_token_symbol is null then '' else '/'||paired2_token_symbol end as paired_token_symbol,
main_token_reserve, paired1_token_reserve as paired_token_reserve,
main_token_usd_reserve,
paired1_token_usd_reserve + coalesce(paired2_token_usd_reserve,0) as paired_token_usd_reserve,
coalesce(trading_volume.trading_volume,0) as trading_volume
from reserves r
left join trading_volume on r.pool_id = trading_volume.poolId and  r.day = trading_volume.time
order by day desc, pool_id
)


select 
blockchain ||' '|| project ||' '|| coalesce(paired_token_symbol,'unknown') ||':'|| main_token_symbol ||'('|| substring(cast(pool as varchar),64) ||')' as pool_name,
* 
from all_metrics
where main_token_reserve > 1

