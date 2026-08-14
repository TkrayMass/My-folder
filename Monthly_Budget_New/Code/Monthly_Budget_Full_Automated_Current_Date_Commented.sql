

USE WAREHOUSE MHA_WH;
USE DATABASE MHTEAM;
USE SCHEMA MHA;
USE ROLE MHA_TEAM_ROLE;


SET start_time = CURRENT_TIMESTAMP();



ALTER SESSION SET STATEMENT_TIMEOUT_IN_SECONDS = 3600;


/*======================================================================
  MONTHLY BUDGET REPORT - FULL REFRESH PROCESS

  PURPOSE:
    Rebuilds the monthly Budget reporting data from source transactions
    through PMPM, LTM, variance, and Tableau patch outputs.

  RUN ORDER:
    1. P1_BUILD_TRANSACTIONS
    2. P2_COMBINE_FEEDS
    3. P3_BUILD_MEM_MONTHS
    4. P4_AGGREGATE_MEASURES
    5. P5_PMPM_MEASURES
    6. P6_LTM
    7. ROLL_FORWARD_LTM_PATCH_TABLE

  AUTOMATION:
    P1 now uses CURRENT_DATE(), so the core monthly reporting dates advance
    automatically when this process is scheduled.

  IMPORTANT:
    Procedure execution order must be preserved because later procedures
    depend on tables created by earlier procedures.
======================================================================*/

/*======================================================================
  PROCEDURE 1: BUDGET_MONTHLY_REWRITE_P1_BUILD_TRANSACTIONS
  PURPOSE:
    Builds the core monthly transaction feeds used by the entire Budget
    reporting process.

  DATE LOGIC:
    - start_date is fixed at 2016-01-01.
    - run_date uses CURRENT_DATE(), so no manual monthly date update is needed.
    - end_date is the last day of the month two months before run_date.
    - remit_endate is run_date + 45 days.
    - These dates are written to BUDGET_MONTHLY_TIME_CONFIG for later procs.

  MAIN OUTPUTS:
    - BUDGET_MONTHLY_DT
    - BUDGET_MONTHLY_aFFS
    - BUDGET_MONTHLY_aMNGC
    - BUDGET_MONTHLY_aMNGO
    - BUDGET_MONTHLY_TIME_CONFIG

  DEPENDENCIES:
    - MHDWPROD claim, member, provider, procedure, managed care, and date tables
    - MHTEAM.MHA.BUDGET_XWALK_PROVIDER_GROUPING_202605

  NEXT STEP:
    P2 combines these separate feeds into one transaction table.
======================================================================*/
CREATE OR REPLACE PROCEDURE MHTEAM.MHA.BUDGET_MONTHLY_REWRITE_P1_BUILD_TRANSACTIONS()
RETURNS VARCHAR(16777216)
LANGUAGE SQL
EXECUTE AS CALLER
AS '
DECLARE
    start_date DATE;
    run_date DATE;
    wh_thru_dt STRING;
    end_date DATE;
    remit_endate DATE;
    RETURN_STR STRING := '''';
BEGIN
    start_date := TO_DATE(''2016-01-01'');
    --start_date := TO_DATE(''2022-07-01'');
    run_date := CURRENT_DATE();
    
    wh_thru_dt := TO_CHAR(run_date);
    end_date := LAST_DAY(DATEADD(MONTH, -2, run_date));
    --end_date := TO_DATE(''2022-09-01'');
    remit_endate := DATEADD(DAY, 45, run_date);

    -- one row per date between start (2022-07-01) and end (run_date -2 months)
	create or replace table BUDGET_MONTHLY_DT as
    select state_fiscal_year, first_dt_of_month, last_dt_of_month,
           state_fiscal_qtr , last_dt_of_qtr, dt
    from MHDWPROD.nw.nw_date where dt between :start_date and :end_date
	;
    
	RETURN_STR:= ''Table BUDGET_MONTHLY_DT created successfully.'';

	create or replace table BUDGET_MONTHLY_aFFS as 
    with
    pharma_vals as (
        select old_bd_typ_ord as pharma_old_bd_typ_ord,
               old_bd_group_ord as pharma_old_bd_group_ord,
               old_bd_group_desc as pharma_old_bd_group_desc,
               budg_prv_grp_char_cd as pharma_budg_prv_grp_char_cd,
               budg_prv_grp_desc as pharma_budg_prv_grp_desc,
               rp_typ_char_cd as pharma_rp_typ_char_cd,
               rp_typ_desc as pharma_rp_typ_desc,
               program_flag as pharma_program_flag
        from MHTEAM.MHA.BUDGET_XWALK_PROVIDER_GROUPING_202605
        where RP_TYP_DESC = ''Pharmacy''
    )
	select ''FFS'' as Source
		 ,prv.cde_disbursement
		 ,dt.state_fiscal_year
		 ,dt.first_dt_of_month
		 ,dt.last_dt_of_month
		 ,clm.dos_from_dt
		 ,cde_clm_type
		 ,prv.CDE_PROV_TYPE
		 ,prv.DSC_PROV_TYPE
         -- If no servicing prv_seq then use billing (which is what MMIS does)
         ,case when clm.servicing_prv_seq is null then trim(prvb.CDE_PROV_TYPE)
               when clm.servicing_prv_seq < 0     then trim(prvb.CDE_PROV_TYPE)
               else trim(prv.CDE_PROV_TYPE)
          end as effective_prov_type
         ,case when cde_clm_type in (''A'',''B'',''C'') then ''XO''
            when cde_clm_type=''D'' and effective_prov_type=''97'' then ''10''
            when cde_clm_type=''H'' and effective_prov_type=''60'' and cde_proc in(''T1002'',''T1003'') then ''CN''
            when cde_clm_type=''M'' and effective_prov_type=''61'' and cde_proc in(''T1002'',''T1003'') then ''CN''
            when effective_prov_type=''62'' and cde_proc=''H0043'' then ''GF''
            when cde_federal_type_of_service =''17'' then ''55''
            when cde_clm_type=''M'' and effective_prov_type=''+'' then ''56''
            when cde_form_type = ''PHRM'' and effective_prov_type=''#'' then ''40''
            -- remaining group practice claims can be Physician
            when effective_prov_type=''97'' then ''01''
            else effective_prov_type
         end as derived_rp_typ_char_cd
        -- if cde_form is pharmacy then assign to pharmacy
        ,case when cde_form_type <> ''PHRM'' then crw.old_bd_typ_ord    else pharma_vals.pharma_old_bd_typ_ord    end as old_bd_typ_ord
        ,case when cde_form_type <> ''PHRM'' then crw.old_bd_group_ord  else pharma_vals.pharma_old_bd_group_ord  end as old_bd_group_ord
        ,case when cde_form_type <> ''PHRM'' then crw.old_bd_group_desc else pharma_vals.pharma_old_bd_group_desc end as old_bd_group_desc
        ,case when cde_form_type <> ''PHRM'' then crw.budg_prv_grp_char_cd else pharma_vals.pharma_budg_prv_grp_char_cd end as budg_prv_grp_char_cd
        ,case when cde_form_type <> ''PHRM'' then crw.budg_prv_grp_desc    else pharma_vals.pharma_budg_prv_grp_desc    end as budg_prv_grp_desc
        ,case when cde_form_type <> ''PHRM'' then crw.rp_typ_char_cd       else pharma_vals.pharma_rp_typ_char_cd       end as rp_typ_char_cd
        ,case when cde_form_type <> ''PHRM'' then crw.rp_typ_desc          else pharma_vals.pharma_rp_typ_desc          end as rp_typ_desc
        ,case when cde_form_type <> ''PHRM'' then crw.program_flag         else pharma_vals.pharma_program_flag         end as program_flag
		,case when clm.cde_clm_type in (''A'',''B'',''C'') then 1 else 0 end flag_Xover
        ,prc.cde_proc
        ,fed.cde_federal_type_of_service
        ,clm.cde_form_type
		,clm.num_logical_claim
		,clm.amt_paid
		,mem.id_medicaid
		,mem.mem_seq
        ,clm.servicing_prv_seq
		,clm.billing_prv_seq
        ,prv.cde_prov_type as servicing_prv_type
        ,prvb.cde_prov_type as billing_prv_type
		,clm.stateelig_seq
        ,clm.clm_seq as transaction_seq
        ,current_date || ''  '' || current_time as created_at
        ,:run_date as run_date
	from MHDWPROD.nw.nw_claim_hist clm
    cross join pharma_vals
	inner join BUDGET_MONTHLY_DT dt on (clm.dos_from_dt = dt.dt)
	inner join MHDWPROD.nw.nw_member_hist mem on (clm.mem_seq = mem.mem_seq)
	inner join MHDWPROD.nw.nw_provider_hist prvb on (clm.billing_prv_seq = prvb.prv_seq)
	inner join MHDWPROD.nw.nw_provider_hist prv on (clm.servicing_prv_seq = prv.prv_seq)
	inner JOIN MHDWPROD.nw.nw_procedure_hist prc ON (prc.proc_seq = clm.proc_seq)
	inner join MHDWPROD.nw.nw_claim_fedrep_attribute fed on fed.attrfr_seq=clm.attrfr_seq
    -- assign type-level (and group-level) based on claim info
	left join MHTEAM.MHA.BUDGET_XWALK_PROVIDER_GROUPING_202605 crw
        on ltrim(trim(derived_rp_typ_char_cd), ''0'') = trim(crw.RP_TYP_CHAR_CD)
	where (:wh_thru_dt between clm.wh_from_dt and clm.wh_thru_dt)
		and clm.remit_dt between :start_date and :remit_endate
		and clm.cde_clm_status = ''P''
		and clm.cde_clm_disposition in (''O'',''A'')
		and clm.ind_offset = ''N''
		and prvb.cde_disbursement in (''0'')
	;

	RETURN_STR:= RETURN_STR || ''Table BUDGET_MONTHLY_aFFS created successfully.'';
	
    create or replace table BUDGET_MONTHLY_aMNGC as 
    with
    pcpr_vals as (
        select old_bd_typ_ord as pcpr_old_bd_typ_ord,
               old_bd_group_ord as pcpr_old_bd_group_ord,
               old_bd_group_desc as pcpr_old_bd_group_desc,
               budg_prv_grp_char_cd as pcpr_budg_prv_grp_char_cd,
               budg_prv_grp_desc as pcpr_budg_prv_grp_desc,
               rp_typ_char_cd as pcpr_rp_typ_char_cd,
               rp_typ_desc as pcpr_rp_typ_desc,
               program_flag as pcpr_program_flag
        from MHTEAM.MHA.BUDGET_XWALK_PROVIDER_GROUPING_202605
        where budg_prv_grp_desc = ''PCPR Capitation''
    )
    select ''MNGC'' as Source
        ,prv.cde_disbursement
        ,dt.state_fiscal_year
        ,dt.first_dt_of_month
        ,dt.last_dt_of_month
        ,mc.PAYMENT_BEGIN_DT as dos_from_dt
        ,''NULL'' as cde_clm_type
        ,prv.CDE_PROV_TYPE
        ,prv.DSC_PROV_TYPE
        ,trim(prv.cde_prov_type) as derived_rp_typ_char_cd
        -- this is when the transaction category code wouldnt be capitation. just set it to PCPR
        ,case when crw.old_bd_group_desc = ''Capitation'' then crw.old_bd_typ_ord    else pcpr_vals.pcpr_old_bd_typ_ord    end as old_bd_typ_ord
        ,case when crw.old_bd_group_desc = ''Capitation'' then crw.old_bd_group_ord  else pcpr_vals.pcpr_old_bd_group_ord  end as old_bd_group_ord
        ,case when crw.old_bd_group_desc = ''Capitation'' then crw.old_bd_group_desc else pcpr_vals.pcpr_old_bd_group_desc end as old_bd_group_desc
        ,case when crw.old_bd_group_desc = ''Capitation'' then crw.budg_prv_grp_char_cd else pcpr_vals.pcpr_budg_prv_grp_char_cd end as budg_prv_grp_char_cd
        ,case when crw.old_bd_group_desc = ''Capitation'' then crw.budg_prv_grp_desc    else pcpr_vals.pcpr_budg_prv_grp_desc    end as budg_prv_grp_desc
        ,crw.rp_typ_char_cd
        ,crw.rp_typ_desc
        ,crw.program_flag
        ,0 as flag_Xover
        ,mc.mc_seq as num_logical_claim
        ,mc.amt_paid
        ,mem.id_medicaid
        ,mem.mem_seq
        ,mc.servicing_prv_seq
        ,mc.billing_prv_seq
        ,mc.stateelig_seq
        ,mc.mc_seq as transaction_seq
        ,current_date || ''  '' || current_time as created_at
        ,:run_date as run_date
    from MHDWPROD.nw.nw_managed_care_hist mc
    cross join pcpr_vals
    inner join BUDGET_MONTHLY_DT dt on (mc.payment_begin_dt = dt.dt)
    inner join MHDWPROD.nw.nw_member_hist mem on (mc.mem_seq = mem.mem_seq)
    inner join MHDWPROD.nw.nw_provider_hist prv on (mc.billing_prv_seq = prv.prv_seq)
    left join MHTEAM.MHA.BUDGET_XWALK_PROVIDER_GROUPING_202605 crw
        on ltrim(trim(prv.cde_prov_type), ''0'') = trim(crw.RP_TYP_CHAR_CD)
    inner join MHDWPROD.nw.nw_rate_cell_hist rc on (mc.ratecell_seq = rc.ratecell_seq)
    inner join MHDWPROD.nw.nw_payment_attribute ap on (mc.attrpay_seq = ap.attrpay_seq)
    where :wh_thru_dt between mc.wh_from_dt and mc.wh_thru_dt 
        and (mc.payment_begin_dt between :start_date and :end_date)  
        and prv.cde_disbursement in (''0'')
        and ap.cde_activity not in (''9999'')
        and mc.cde_payment_type_mc = ''C''
    ;

	RETURN_STR:= RETURN_STR ||  ''Table BUDGET_MONTHLY_aMNGC created successfully.'';

    create or replace table BUDGET_MONTHLY_aMNGO as
    select ''MNGO'' as Source
        ,prv.cde_disbursement
        ,dt.state_fiscal_year
        ,dt.first_dt_of_month
        ,dt.last_dt_of_month
        ,mc.PAYMENT_BEGIN_DT as dos_from_dt
        ,''NULL'' as cde_clm_type
        ,prv.CDE_PROV_TYPE
        ,prv.DSC_PROV_TYPE
        ,trim(prv.cde_prov_type) as derived_rp_typ_char_cd
        ,130 as old_bd_typ_ord
        ,11 as old_bd_group_ord
        ,''Capitation'' as old_bd_group_desc
        ,''OCap'' as budg_prv_grp_char_cd
        ,''Other Capitation'' as budg_prv_grp_desc
        ,crw.rp_typ_char_cd
        ,crw.rp_typ_desc
        ,crw.program_flag
        ,0 as flag_Xover
        ,mc.mc_seq as num_logical_claim
        ,mc.amt_paid
        ,mem.id_medicaid
        ,mem.mem_seq
        ,mc.servicing_prv_seq
        ,mc.billing_prv_seq
        ,null as stateelig_seq
        ,mc.mc_seq as transaction_seq
        ,current_date || ''  '' || current_time as created_at
        ,:run_date as run_date
    from MHDWPROD.nw.nw_managed_care_hist mc
    inner join BUDGET_MONTHLY_DT dt on (mc.payment_begin_dt = dt.dt)
    inner join MHDWPROD.nw.nw_member_hist mem on (mc.mem_seq = mem.mem_seq)
    inner join MHDWPROD.nw.nw_provider_hist prv on (mc.billing_prv_seq = prv.prv_seq)
    left join MHTEAM.MHA.BUDGET_XWALK_PROVIDER_GROUPING_202605 crw
        on ltrim(trim(prv.cde_prov_type), ''0'') = trim(crw.RP_TYP_CHAR_CD)
    inner join MHDWPROD.nw.nw_rate_cell_hist rc on (mc.ratecell_seq = rc.ratecell_seq)
    inner join MHDWPROD.nw.nw_payment_attribute ap on (mc.attrpay_seq = ap.attrpay_seq)
    where :wh_thru_dt between mc.wh_from_dt and mc.wh_thru_dt
        and (mc.payment_begin_dt between :start_date and :end_date) 
        and prv.cde_disbursement = ''0''
        and ap.cde_activity not in (''9999'')
        and mc.cde_payment_type_mc = ''O''
    ;


	RETURN_STR:= RETURN_STR ||  ''Table BUDGET_MONTHLY_aMNGO created successfully.'';

    create or replace table BUDGET_MONTHLY_TIME_CONFIG as
    select :start_date as start_date,
           :run_date as run_date,
           :wh_thru_dt as wh_thru_dt,
           :end_date as end_date,
           :remit_endate as remit_endate
    ;

    RETURN RETURN_STR;
END;
';



CALL MHTEAM.MHA.BUDGET_MONTHLY_REWRITE_P1_BUILD_TRANSACTIONS();






-- 17m 35s
/*======================================================================
  PROCEDURE 2: BUDGET_MONTHLY_REWRITE_P2_COMBINE_FEEDS
  PURPOSE:
    Combines the FFS, managed care capitation, and other managed care feeds
    created in P1 into one consolidated monthly transaction table.

  MAIN WORK:
    - UNION ALLs BUDGET_MONTHLY_aFFS, BUDGET_MONTHLY_aMNGC,
      and BUDGET_MONTHLY_aMNGO.
    - Uses the maximum run_date from the combined feeds.
    - Joins transactions to eligibility history.
    - Adds demographic and plan type groupings.
    - Adds Tableau sort-order fields.

  MAIN OUTPUT:
    - BUDGET_MONTHLY_TRANSACTIONS

  DEPENDENCIES:
    - P1 output tables
    - MHDWPROD.MHADL.MHA_DL_STATE_ELIGIBILITY_HIST
    - MHTEAM.MHA.BUDGET_XWALK_MEMBER_GROUPING
    - MHTEAM.MHA.BUDGET_SORT_ORDER_202605

  NEXT STEP:
    P3 builds monthly eligibility/member-month denominators.
======================================================================*/
CREATE OR REPLACE PROCEDURE MHTEAM.MHA.BUDGET_MONTHLY_REWRITE_P2_COMBINE_FEEDS()
RETURNS VARCHAR(16777216)
LANGUAGE SQL
EXECUTE AS CALLER
AS '
DECLARE
    RETURN_STR STRING := '''';

BEGIN
    create or replace table BUDGET_MONTHLY_TRANSACTIONS as
    with
    combined as (

        -- FFS except Other FFS (Xover, Special Programs, and FFS Other)
        select source, dos_from_dt,
               state_fiscal_year, first_dt_of_month,
               clm.rp_typ_char_cd,
               clm.budg_prv_grp_char_cd as cde_report,
               clm.rp_typ_desc as provider_type,
               clm.budg_prv_grp_desc as provider_group,
               clm.old_bd_group_desc as provider_category,
               amt_paid, id_medicaid, mem_seq,
               stateelig_seq,
               transaction_seq,
               run_date,
               created_at as data_pulled_at,
               -- debug info
               clm.derived_rp_typ_char_cd,
               clm.old_bd_typ_ord,
               clm.old_bd_group_ord,
               clm.program_flag,
               clm.flag_xover,
               clm.cde_proc,
               clm.cde_federal_type_of_service,
               clm.cde_form_type
        from BUDGET_MONTHLY_aFFS clm

        union all

        select source, dos_from_dt,
               state_fiscal_year, first_dt_of_month,
               rp_typ_char_cd,
               budg_prv_grp_char_cd as cde_report,
               rp_typ_desc as provider_type,
               budg_prv_grp_desc as provider_group,
               old_bd_group_desc as provider_category,
               amt_paid, id_medicaid, mem_seq,
               stateelig_seq,
               transaction_seq,
               run_date,
               created_at as data_pulled_at,
               -- debug info
               derived_rp_typ_char_cd,
               old_bd_typ_ord,
               old_bd_group_ord,
               program_flag,
               flag_xover,
               null as cde_proc,
               null as cde_federal_type_of_service,
               null as cde_form_type
        from BUDGET_MONTHLY_aMNGC
        where 1=1

        union all

        select source, dos_from_dt,
               state_fiscal_year, first_dt_of_month,
               rp_typ_char_cd,
               budg_prv_grp_char_cd as cde_report,
               rp_typ_desc as provider_type,
               budg_prv_grp_desc as provider_group,
               old_bd_group_desc as provider_category,
               amt_paid, id_medicaid, mem_seq,
               stateelig_seq, -- is null
               transaction_seq,
               run_date,
               created_at as data_pulled_at,
               -- debug info
               derived_rp_typ_char_cd,
               old_bd_typ_ord,
               old_bd_group_ord,
               program_flag,
               flag_xover,
               null as cde_proc,
               null as cde_federal_type_of_service,
               null as cde_form_type
        from BUDGET_MONTHLY_aMNGO
        where 1=1
    ),
    -- get the max run date from combined table
    run_date_max as (
        select max(run_date) as run_date
        from combined
    ),
    elig as (
        select
            se.id_medicaid,
            se.stateelig_seq,
            se.cde_managed_care_plan,
            se.cde_managed_care_plan_l2,
            se.ind_medicare_a,
            se.ind_medicare_b,
            se.cde_budget_group,
            se.dte_effective, se.dte_end
            --se.dte_effective_by_month as dte_effective, se.dte_end_by_month as dte_end,
        from mhdwprod.mhadl.mha_dl_state_eligibility_hist se
        --from mhdwprod.mhadl.mha_state_eligibility_by_month se
        cross join run_date_max rdm
        where rdm.run_date between se.valid_from_dt_tm and se.valid_thru_dt_tm
    ),
    sort_order_dedup as (
        select granularity, label, rank
        from (
            select
                granularity,
                label,
                rank,
                row_number() over (
                    partition by granularity, label
                    order by rank
                ) as rn
            from mhteam.mha.BUDGET_SORT_ORDER_202605
        ) s
        where rn = 1
    )
    select b.*,
           elig.cde_managed_care_plan,
           elig.cde_managed_care_plan_l2,
           elig.ind_medicare_a,
           elig.ind_medicare_b,
           elig.cde_budget_group,
           NVL(bg.demo, ''Unmatched Member'') as demographic,
           NVL(bg.plantype, ''Unmatched Member'') as plantype,
           so_cat.rank as sort_order_category,
           so_grp.rank as sort_order_group,
           so_typ.rank as sort_order_type,
           so_demo.rank as sort_order_demo,
           so_plan.rank as sort_order_plantype,
           b.stateelig_seq as transaction_stateelig_seq,
           elig.stateelig_seq as elig_stateelig_seq
    from combined b
    left join elig
        --on b.stateelig_seq = elig.stateelig_seq
        on b.id_medicaid = elig.id_medicaid
        and b.dos_from_dt between elig.dte_effective and elig.dte_end
    left join MHTEAM.MHA.BUDGET_XWALK_MEMBER_GROUPING bg
        on elig.cde_budget_group = bg.cde_budget_group
    -- join to ordering table to get sort order for tableau
    left join sort_order_dedup so_cat
        on so_cat.granularity = ''Category''
        and so_cat.label = b.provider_category
    left join sort_order_dedup so_grp
        on so_grp.granularity = ''Group''
        and so_grp.label = b.provider_group
    left join sort_order_dedup so_typ
        on so_typ.granularity = ''Type''
        and so_typ.label = b.provider_type
    left join sort_order_dedup so_demo
        on so_demo.granularity = ''Demographic''
        and so_demo.label = demographic
    left join sort_order_dedup so_plan
        on so_plan.granularity = ''Plan Type''
        and so_plan.label = NVL(bg.plantype, ''Unmatched Member'')
    where 1=1
    ;

	RETURN_STR:= RETURN_STR ||  ''Table BUDGET_MONTHLY_TRANSACTIONS created successfully.'';

    RETURN RETURN_STR;
END;
';




CALL MHTEAM.MHA.BUDGET_MONTHLY_REWRITE_P2_COMBINE_FEEDS();



select *
from BUDGET_MONTHLY_TRANSACTIONS
where 1=1
and first_dt_of_month = '2022-07-01'
limit 50
;


-------------------------------------------------------


-- 2m 33s

-- get the member months for each group
/*======================================================================
  PROCEDURE 3: BUDGET_MONTHLY_REWRITE_P3_BUILD_MEM_MONTHS
  PURPOSE:
    Builds monthly eligibility and member-month measures used as
    denominators for PMPM reporting.

  DATE LOGIC:
    Reads start_date, run_date, wh_thru_dt, end_date, and remit_endate
    from BUDGET_MONTHLY_TIME_CONFIG created by P1.

  MAIN WORK:
    - Pulls eligible members for the reporting period.
    - Derives plan type and demographic groupings.
    - Calculates eligible days and converts them to member months.
    - Produces grouped monthly member counts with Tableau sort order.

  MAIN OUTPUTS:
    - BUDGET_MONTHLY_MEMBERELIG
    - BUDGET_MONTHLY_MEMBERMONTH
    - BUDGET_MONTHLY_MEMBERMONTH_GROUPED

  DEPENDENCIES:
    - P1 BUDGET_MONTHLY_TIME_CONFIG
    - MHDWPROD eligibility and member crosswalk tables
    - MHTEAM.MHA.BUDGET_XWALK_MEMBER_GROUPING
    - MHTEAM.MHA.BUDGET_SORT_ORDER_202605

  NEXT STEP:
    P4 aggregates spending/utilizer measures.
======================================================================*/
CREATE OR REPLACE PROCEDURE MHTEAM.MHA.BUDGET_MONTHLY_REWRITE_P3_BUILD_MEM_MONTHS()
RETURNS VARCHAR(16777216)
LANGUAGE SQL
EXECUTE AS CALLER
AS '
DECLARE
    start_date DATE;
    run_date DATE;
    wh_thru_dt STRING;
    end_date DATE;
    remit_endate DATE;
    RETURN_STR STRING := '''';
BEGIN
    start_date   := (select start_date from BUDGET_MONTHLY_TIME_CONFIG);
    run_date     := (select run_date from BUDGET_MONTHLY_TIME_CONFIG);
    wh_thru_dt   := (select wh_thru_dt from BUDGET_MONTHLY_TIME_CONFIG);
    end_date     := (select end_date from BUDGET_MONTHLY_TIME_CONFIG);
    remit_endate := (select remit_endate from BUDGET_MONTHLY_TIME_CONFIG);

	create or replace table BUDGET_MONTHLY_MEMBERELIG as
	with
    CTE_SE as (
        select distinct se.stateelig_seq
        from MHDWPROD.nw.nw_state_eligibility_hist se
        where se.dte_effective <= :end_date and se.dte_end >= :start_date
        and :wh_thru_dt between se.valid_from_dt_tm and se.valid_thru_dt_tm
        and nvl(coverage_category,''None'') not in(''+'',''-'',''#'',''None'')
        order by se.stateelig_seq
	)
	select xref.id_medicaid_crnt,
           sem.state_fiscal_year, sem.first_dt_of_month, sem.last_dt_of_month,
           sem.dte_effective, sem.dte_end,
           case when sem.cde_managed_care_plan = ''MCO-MassHealth'' then ''MCO''
		       when sem.cde_managed_care_plan = ''ACOA-MassHealth'' then ''ACO A''
		       when sem.cde_managed_care_plan = ''ACOB-MassHealth'' then ''ACO B''
		       when sem.cde_managed_care_plan = ''FFS'' then 
		   	    (case when sem.cde_managed_care_plan_l2 = ''MassHealth Eligible'' then
                                (case when se.ind_medicare_A = ''Y'' then ''FFS Duals''
					                  when se.ind_medicare_B = ''Y'' then ''FFS Duals''
						              when tpl.stateelig_seq is not null then ''FFS TPL''
					                  else ''FFS'' end)
				                      else ''Other'' end)
			    when sem.cde_managed_care_plan = ''PCC'' then ''PCC''
                when sem.cde_managed_care_plan = ''MCO-CommCare'' then ''MCO-CommCare''
                when sem.cde_managed_care_plan = ''SCO'' then ''SCO''
                when sem.cde_managed_care_plan = ''ICO'' then ''ICO''
                when sem.cde_managed_care_plan = ''PACE'' then ''PACE''
                when sem.cde_managed_care_plan = ''Exception'' then ''Exception''
                else ''NA''
           end as Plan_Type,
           bg.PlanType,
           sem.cde_budget_group,
           sem.cde_pgm_health,
           case when length(bg.Demo)>0 then bg.Demo  else ''NULL'' end as demographic,
           sem.num_elig_days_in_month,
           :run_date as run_date
	from MHDWPROD.nw.nw_state_eligibility_hist se
	left join MHDWPROD.nw.nw_member_xref_medicaid xref 
	   on se.mem_seq = xref.mem_seq
	inner join MHDWPROD.nw.NW_STATE_ELIGIBILITY_BY_MONTH sem
        on sem.first_dt_of_month >= :start_date 
        and sem.last_dt_of_month <= :end_date
        and se.sak_recip = sem.sak_recip
        and sem.dte_effective between se.dte_effective and se.dte_end
	left join CTE_SE tpl
        on se.stateelig_seq = tpl.stateelig_seq
	left join MHTEAM.MHA.BUDGET_XWALK_MEMBER_GROUPING bg
        on sem.cde_budget_group = bg.cde_budget_group
	where se.dte_effective <= :end_date
    and se.dte_end >= :start_date 
    and (:wh_thru_dt between se.valid_from_dt_tm and se.valid_thru_dt_tm)
    and se.stateelig_seq > 0
    and se.ind_active = ''Y''
	;
	
	RETURN_STR := RETURN_STR ||  ''Table BUDGET_MONTHLY_MEMBERELIG created successfully.'';	

	create or replace table BUDGET_MONTHLY_MEMBERMONTH as
	with
    cte_mem as (
	    select state_fiscal_year, first_dt_of_month, last_dt_of_month,
               cde_budget_group, plan_type, plantype, cde_pgm_health, demographic,
               sum(num_elig_days_in_month) as sum_elig_days_in_month
        from BUDGET_MONTHLY_MEMBERELIG
        where plan_type not in (''Exception'',''MCO-CommCare'',''Other'') and cde_budget_group not in (''99'')
        group by all
	)
	select *, 
   		   date_part(year, first_dt_of_month) as cy,
		   TO_VARCHAR(first_dt_of_month, ''yyyyMM'') as month,
		   DATEADD(MONTH, 6, first_dt_of_month) as qtr_sfy,
		   DATEDIFF(day, TO_DATE(first_dt_of_month), TO_DATE(last_dt_of_month)+1) as days_in_month,
		   sum_elig_days_in_month/days_in_month as members_in_month,
		   case when cde_budget_group = ''AA'' then ''AA'' else ''Non-AA'' end as flag_aa,
           :run_date as run_date
    from cte_mem 
	;

	RETURN_STR := RETURN_STR ||  ''Table BUDGET_MONTHLY_MEMBERMONTH created successfully.'';


    create or replace table BUDGET_MONTHLY_MEMBERMONTH_GROUPED as
    select state_fiscal_year, month,
            plantype, demographic,
            sum(members_in_month) as members_in_month,
            so_demo.rank as sort_order_demo,
            so_plan.rank as sort_order_plantype,
            run_date as run_date
    from BUDGET_MONTHLY_MEMBERMONTH
    left join mhteam.mha.BUDGET_SORT_ORDER_202605 so_demo
        on so_demo.granularity = ''Demographic''
        and so_demo.label = demographic
    left join mhteam.mha.BUDGET_SORT_ORDER_202605 so_plan
        on so_plan.granularity = ''Plan Type''
        and so_plan.label = plantype
    group by all
    ;

	RETURN_STR := RETURN_STR ||  ''Table BUDGET_MONTHLY_MEMBERMONTH_GROUPED created successfully.'';
 
    RETURN RETURN_STR;
END;
';


CALL MHTEAM.MHA.BUDGET_MONTHLY_REWRITE_P3_BUILD_MEM_MONTHS();




select *
from BUDGET_MONTHLY_MEMBERMONTH_GROUPED
where month = '202207'
order by sort_order_plantype, sort_order_demo
;




-------------------------------------------------------




-- 14m 22s
/*======================================================================
  PROCEDURE 4: BUDGET_MONTHLY_REWRITE_P4_AGGREGATE_MEASURES
  PURPOSE:
    Aggregates the consolidated transaction table into Budget dashboard
    spending and utilization measures at multiple provider levels.

  MAIN WORK:
    - Provider Category aggregation
    - Provider Group aggregation
    - Provider Type aggregation
    - Total Fee For Service Spend
    - Total Programmatic Spend
    - Paid per utilizer calculations
    - Preserves sort-order fields for Tableau

  MAIN OUTPUTS:
    - BUDGET_MONTHLY_AMT_STAGE3
    - BUDGET_MONTHLY_AMT_STAGE4
    - BUDGET_MONTHLY_AMT_STAGE4_MODIFIED
    - BUDGET_MONTHLY_AMT_STAGE5
    - BUDGET_MONTHLY_AMT_STAGE6

  DEPENDENCY:
    - P2 BUDGET_MONTHLY_TRANSACTIONS

  NEXT STEP:
    P5 builds PMPM measures using transaction spend plus P3 member months.
======================================================================*/
CREATE OR REPLACE PROCEDURE MHTEAM.MHA.BUDGET_MONTHLY_REWRITE_P4_AGGREGATE_MEASURES()
RETURNS VARCHAR(16777216)
LANGUAGE SQL
EXECUTE AS CALLER
AS '
DECLARE
    RETURN_STR STRING := '''';
BEGIN

    -- Provider Category view
    CREATE OR REPLACE TABLE BUDGET_MONTHLY_AMT_STAGE3 as
    select count(distinct id_medicaid) as cnt_id_medicaid,
           sum(amt_paid) / nullif(count(distinct id_medicaid),0) as PaidPerID,
           sum(amt_paid) as sum_amt_paid,
           to_varchar(first_dt_of_month, ''YYYYMM'') as month,
           provider_category as group_report,
           sort_order_category,
           state_fiscal_year,
           run_date,
           ''Category'' as granularity
    from BUDGET_MONTHLY_TRANSACTIONS
    where 1=1
    group by all
    union all
    -------------------------------------------
    -- Total FFS Spend
    -------------------------------------------
    select count(distinct id_medicaid) as cnt_id_medicaid,
           sum(amt_paid) / nullif(count(distinct id_medicaid),0) as PaidPerID,
           sum(amt_paid) as sum_amt_paid,
           to_varchar(first_dt_of_month, ''YYYYMM'') as month,
           ''Total Fee For Service Spend'' as group_report,
           -- to ensure FFS total appears after all categories but before the programmatic total
           (select max(sort_order_category) - 0.01
            from BUDGET_MONTHLY_TRANSACTIONS
            where provider_category = ''Capitation''
           ) as sort_order_category,
           state_fiscal_year,
           run_date,
           ''Total FFS'' as granularity
    from BUDGET_MONTHLY_TRANSACTIONS
    where 1=1
    and provider_category <> ''Capitation''
    group by all
    union all
    -------------------------------------------
    -- Total Programmatic Spend
    -------------------------------------------
    select count(distinct id_medicaid) as cnt_id_medicaid,
           sum(amt_paid) / nullif(count(distinct id_medicaid),0) as PaidPerID,
           sum(amt_paid) as sum_amt_paid,
           to_varchar(first_dt_of_month, ''YYYYMM'') as month,
           ''Programmatic Spend'' as group_report,
           1000 as sort_order_category,
           state_fiscal_year,
           run_date,
           ''Total Programmatic Spend'' as granularity
    from BUDGET_MONTHLY_TRANSACTIONS
    where 1=1
    group by all
    ;

	RETURN_STR:= RETURN_STR ||  ''Table BUDGET_MONTHLY_AMT_STAGE3 created successfully.'';

    --------------------------------------------------------------------

    -- Provider Group view

    create or replace table BUDGET_MONTHLY_AMT_STAGE4 as
    -------------------------------------------
    -- Group-level rows
    -------------------------------------------
    select provider_group as group_rpt,
           provider_category as group_report_label,
           count(distinct case when id_medicaid<>''#'' then id_medicaid end) as total_unique_members,
           sum(amt_paid) as total_paid,
           sum(amt_paid) / nullif(total_unique_members,0) as paid_per_utilizer,
           to_varchar(first_dt_of_month, ''YYYYMM'') as month,
           sort_order_category,
           sort_order_group,
           state_fiscal_year,
           run_date,
           ''Group'' as granularity
    from BUDGET_MONTHLY_TRANSACTIONS
    where 1=1
    group by all
    union all
    -------------------------------------------
    -- Category-level Totals
    -------------------------------------------
    select ''Total - '' || provider_category as group_rpt,
           provider_category as group_report_label,
           count(distinct id_medicaid) as total_unique_members,
           sum(amt_paid) as total_paid,
           sum(amt_paid) / nullif(count(distinct id_medicaid),0) as paid_per_utilizer,
           to_varchar(first_dt_of_month, ''YYYYMM'') as month,
           sort_order_category,
           1000 as sort_order_group,
           state_fiscal_year,
           run_date,
           ''Category'' as granularity
    from BUDGET_MONTHLY_TRANSACTIONS
    where 1=1
    group by all
    union all
    -------------------------------------------
    -- Total FFS Spend
    -------------------------------------------
    select ''Total Fee For Service Spend'' as group_rpt,
           ''Total Fee For Service Spend'' as group_report_label,
           count(distinct id_medicaid) as total_unique_members,
           sum(amt_paid) as total_paid,
           sum(amt_paid) / nullif(count(distinct id_medicaid),0) as paid_per_utilizer,
           to_varchar(first_dt_of_month, ''YYYYMM'') as month,
           max(sort_order_category)+0.1 as sort_order_category,
           1002 as sort_order_group,
           state_fiscal_year,
           run_date,
           ''Total FFS'' as granularity
    from BUDGET_MONTHLY_TRANSACTIONS
    where 1=1
    and provider_category <> ''Capitation''
    group by all
    union all
    -------------------------------------------
    -- Total Programmatic Spend
    -------------------------------------------
    select ''Total Programmatic Spend'' as group_rpt,
           ''Total FFS + Capitation'' as group_report_label,
           count(distinct id_medicaid) as total_unique_members,
           sum(amt_paid) as total_paid,
           sum(amt_paid) / nullif(count(distinct id_medicaid),0) as paid_per_utilizer,
           to_varchar(first_dt_of_month, ''YYYYMM'') as month,
           1004 as sort_order_category,
           1005 as sort_order_group,
           state_fiscal_year,
           run_date,
           ''Total Programmatic Spend'' as granularity
    from BUDGET_MONTHLY_TRANSACTIONS
    where 1=1
    group by all
    ;

	RETURN_STR:= RETURN_STR ||  ''Table BUDGET_MONTHLY_AMT_STAGE4 created successfully.'';

    --------------------------------------------------------------------

    -- Dec dashboard had _modified, but it should now be same
    create or replace table budget_monthly_amt_stage4_modified as
    select *
    from budget_monthly_amt_stage4
    ;

    --------------------------------------------------------------------

    create or replace table budget_monthly_amt_stage5 as
    -------------------------------------------
    -- Type-level rows
    -------------------------------------------
    select provider_type as rp_typ_desc,
           provider_group,
           provider_category as group_report_label,
           count(distinct id_medicaid) as total_unique_members,
           sum(amt_paid) as total_paid,
           sum(amt_paid) / nullif(count(distinct id_medicaid),0) as paid_per_utilizer,
           to_varchar(first_dt_of_month, ''YYYYMM'') as month,
           sort_order_category,
           sort_order_group,
           sort_order_type,
           state_fiscal_year,
           run_date,
           ''Type'' as granularity
    from BUDGET_MONTHLY_TRANSACTIONS
    where 1=1
    group by all
    union all
    -------------------------------------------
    -- Group-level rows
    -------------------------------------------
    select ''Total '' || provider_group as rp_typ_desc,
           provider_group,
           provider_category as group_report_label,
           count(distinct id_medicaid) as total_unique_members,
           sum(amt_paid) as total_paid,
           sum(amt_paid) / nullif(count(distinct id_medicaid),0) as paid_per_utilizer,
           to_varchar(first_dt_of_month, ''YYYYMM'') as month,
           sort_order_category,
           sort_order_group,
           1000 as sort_order_type,
           state_fiscal_year,
           run_date,
           ''Group'' as granularity
    from BUDGET_MONTHLY_TRANSACTIONS t
    where 1=1
    -- checks for singleton groups
    and exists (
        select 1
        from BUDGET_MONTHLY_TRANSACTIONS t2
        where t2.provider_group = t.provider_group
        and t2.provider_category = t.provider_category
        group by t2.provider_group, t2.provider_category
        having count(distinct t2.provider_type) > 1
    )
    group by all
    --having count(distinct provider_type)>1 -- dont have rollup for singletons
    union all
    -------------------------------------------
    -- Category-level Totals
    -------------------------------------------
    select ''Total '' || provider_category as rp_typ_desc,
           provider_category as provider_group,
           provider_category as group_report_label,
           count(distinct id_medicaid) as total_unique_members,
           sum(amt_paid) as total_paid,
           sum(amt_paid) / nullif(count(distinct id_medicaid),0) as paid_per_utilizer,
           to_varchar(first_dt_of_month, ''YYYYMM'') as month,
           sort_order_category,
           1000 as sort_order_group,
           1000 as sort_order_type,
           state_fiscal_year,
           run_date,
           ''Category'' as granularity
    from BUDGET_MONTHLY_TRANSACTIONS t
    where 1=1
    -- checks for singleton groups
    and exists (
        select 1
        from BUDGET_MONTHLY_TRANSACTIONS t2
        where t2.provider_category = t.provider_category
        group by t2.provider_category
        having count(distinct t2.provider_group) > 1
    )
    group by all
    union all
    -------------------------------------------
    -- Total FFS Spend
    -------------------------------------------
    select ''Total Fee For Service Spend'' as rp_typ_desc,
           ''Total Fee For Service Spend'' as provider_group,
           ''Total Fee For Service Spend'' as group_report_label,
           count(distinct id_medicaid) as total_unique_members,
           sum(amt_paid) as total_paid,
           sum(amt_paid) / nullif(count(distinct id_medicaid),0) as paid_per_utilizer,
           to_varchar(first_dt_of_month, ''YYYYMM'') as month,
           max(sort_order_category)+0.1 as sort_order_category,
           1000 as sort_order_group,
           1000 as sort_order_type,
           state_fiscal_year,
           run_date,
           ''Total FFS'' as granularity
    from BUDGET_MONTHLY_TRANSACTIONS
    where 1=1
    and provider_category <> ''Capitation''
    group by all
    union all
    -------------------------------------------
    -- Total Programmatic Spend
    -------------------------------------------
    select ''Total Programmatic Spend'' as rp_typ_desc,
           ''Total FFS + Capitation'' as provider_group,
           ''Total FFS + Capitation'' as group_report_label,
           count(distinct id_medicaid) as total_unique_members,
           sum(amt_paid) as total_paid,
           sum(amt_paid) / nullif(count(distinct id_medicaid),0) as paid_per_utilizer,
           to_varchar(first_dt_of_month, ''YYYYMM'') as month,
           1001 as sort_order_category,
           1001 as sort_order_group,
           1001 as sort_order_type,
           state_fiscal_year,
           run_date,
           ''Total Programmatic Spend'' as granularity
    from BUDGET_MONTHLY_TRANSACTIONS
    where 1=1
    group by all
    ;

	RETURN_STR := RETURN_STR ||  ''Table BUDGET_MONTHLY_AMT_STAGE5 created successfully.'';

    --------------------------------------------------------------------
    
    -- Stage 6: Maybe used to be different from Stage 4 but now same
    CREATE OR REPLACE TABLE BUDGET_MONTHLY_AMT_STAGE6 AS
    select group_rpt as rp_typ_desc,
           group_rpt as provider_group,
           group_report_label,
           total_unique_members, total_paid, paid_per_utilizer,
           month,
           state_fiscal_year,
           sort_order_category, sort_order_group,
           run_date, granularity
    from BUDGET_MONTHLY_AMT_STAGE4
    ;

	RETURN_STR := RETURN_STR ||  ''Table BUDGET_MONTHLY_AMT_STAGE6 created successfully.'';

    --------------------------------------------------------------------

    RETURN RETURN_STR;
END;
';

CALL MHTEAM.MHA.BUDGET_MONTHLY_REWRITE_P4_AGGREGATE_MEASURES();



-- this confirms the ordering
select group_report_label, group_rpt,
         total_unique_members, total_paid, paid_per_utilizer, month,
         sort_order_category, sort_order_group
from BUDGET_MONTHLY_AMT_STAGE4
where 1=1
and month = '202207'
order by sort_order_category, sort_order_group
;


-------------------------------------------------------


-- 1m 31s
/*======================================================================
  PROCEDURE 5: BUDGET_MONTHLY_REWRITE_P5_PMPM_MEASURES
  PURPOSE:
    Builds monthly and quarterly PMPM measures for demographic,
    plan type, and provider-category reporting.

  MAIN WORK:
    - Monthly Demo x Plan PMPM
    - Monthly Plan x Demo PMPM
    - Demo x Provider Category PMPM
    - Plan x Provider Category PMPM
    - Overall monthly PMPM
    - Quarterly demographic PMPM and trends
    - Quarterly plan-type PMPM and trends

  IMPORTANT:
    Quarterly PMPM uses summed quarterly spend divided by summed monthly
    member-month denominators across the quarter.

  MAIN OUTPUTS / VIEWS:
    - BUDGET_MONTHLY_DEMOBYPLAN
    - BUDGET_MONTHLY_PLANBYDEMO
    - BUDGET_MONTHLY_PMPM_DEMOBYPT
    - BUDGET_MONTHLY_PMPM_PLANBYPT
    - BUDGET_MONTHLY_PMPM
    - BUDGET_MONTHLY_PMPM_DEMO_QTR
    - BUDGET_MONTHLY_PMPM_PLAN_QTR

  DEPENDENCIES:
    - P2 BUDGET_MONTHLY_TRANSACTIONS
    - P3 BUDGET_MONTHLY_MEMBERMONTH

  NEXT STEP:
    P6 creates LTM, variance, and snapshot-history outputs.
======================================================================*/
CREATE OR REPLACE PROCEDURE MHTEAM.MHA.BUDGET_MONTHLY_REWRITE_P5_PMPM_MEASURES()
RETURNS VARCHAR(16777216)
LANGUAGE SQL
EXECUTE AS CALLER
AS '
DECLARE
    RETURN_STR STRING := '''';
BEGIN

    -- 16s
    create or replace table BUDGET_MONTHLY_DEMOBYPLAN_STG as
    with
    mem_months as (
        select state_fiscal_year, to_char(first_dt_of_month, ''YYYYMM'') as month,
            demographic, plantype,
            sum(members_in_month) as members_in_month
        from BUDGET_MONTHLY_MEMBERMONTH
        group by all
    ),
    mem_spend as (
        select state_fiscal_year, to_char(first_dt_of_month, ''YYYYMM'') as month,
            demographic, plantype,
            sum(amt_paid) as sum_amt_paid,
            sort_order_demo, sort_order_plantype
        from BUDGET_MONTHLY_TRANSACTIONS
        group by all
    ),
    -- 31 rows of Demo x Plan Type
    pmpm as (
        select mm.*,
            ms.sum_amt_paid, ms.sum_amt_paid/mm.members_in_month as pmpm,
            mm.demographic as pmpm_type, mm.Plantype as group_name,
            ms.sort_order_demo, ms.sort_order_plantype
        from mem_months mm
        left join mem_spend ms
            on mm.state_fiscal_year = ms.state_fiscal_year
            and mm.month = ms.month
            and mm.demographic = ms.demographic
            and mm.plantype = ms.plantype 
        where 1=1
    ),
    -- 9 rows of Demos
    pmpm_subtotals as (
        select state_fiscal_year, month,
            demographic, ''Total'' as plantype,
            sum(members_in_month) as members_in_month,
            sum(sum_amt_paid) as sum_amt_paid,
            sum(sum_amt_paid) / sum(members_in_month) as pmpm,
            demographic as pmpm_type, ''Total'' as group_name,
            sort_order_demo, 1000 as sort_order_plantype
        from pmpm
        group by all
    ),
    -- 1 row (sum of all spend except MNGO aka Other Capitation)
    pmpm_total as (
        select state_fiscal_year, month,
            ''MassHealth Total'' as demographic, ''Total'' as plantype,
            sum(members_in_month) as members_in_month,
            sum(sum_amt_paid) as sum_amt_paid,
            sum(sum_amt_paid) / sum(members_in_month) as pmpm,
            ''MassHealth Total'' as pmpm_type, ''Total'' as group_name,
            1001 as sort_order_demo, 1000 as sort_order_plantype
        from pmpm
        group by all
    ),
    -- 1 row (Sum of all spend that has associated member months, aka everything but MNGO)
    grand_total_spend as (
        select state_fiscal_year, to_char(first_dt_of_month, ''YYYYMM'') as month,
            ''Grand Total'' as demographic, '''' as plantype,
            0 as members_in_month,
            sum(amt_paid) as sum_amt_paid,
            0 as pmpm,
            ''Grand Total'' as pmpm_type, '''' as group_name,
            1004 as sort_order_demo, 1004 as sort_order_plantype
        from BUDGET_MONTHLY_TRANSACTIONS
        group by all
    ),
    -- 1 row (MNGO, derived as Total - Everything else, to guarantee it ties)
    non_mh_spend as (
        select gt.state_fiscal_year, gt.month,
            ''Non-Member Specifc'' as demographic, '''' as plantype,
            0 as members_in_month,
            gt.sum_amt_paid - pt.sum_amt_paid as sum_amt_paid,
            0 as pmpm,
            ''Non-Member Specifc'' as pmpm_type, '''' as group_name,
            1003 as sort_order_demo, 1003 as sort_order_plantype
        from grand_total_spend gt
        inner join pmpm_total pt
            on  gt.state_fiscal_year = pt.state_fiscal_year
            and gt.month = pt.month
    ),
    combined as (
        select state_fiscal_year, month, members_in_month, sum_amt_paid, pmpm, pmpm_type, group_name, sort_order_demo, sort_order_plantype
        from pmpm
        --
        union all
        --
        select state_fiscal_year, month, members_in_month, sum_amt_paid, pmpm, pmpm_type, group_name, sort_order_demo, sort_order_plantype
        from pmpm_subtotals
        --
        union all
        --
        select state_fiscal_year, month, members_in_month, sum_amt_paid, pmpm, pmpm_type, group_name, sort_order_demo, sort_order_plantype
        from pmpm_total
        --
        union all
        --
        select state_fiscal_year, month, members_in_month, sum_amt_paid, pmpm, pmpm_type, group_name, sort_order_demo, sort_order_plantype
        from grand_total_spend
        --
        union all
        --
        select state_fiscal_year, month, members_in_month, sum_amt_paid, pmpm, pmpm_type, group_name, sort_order_demo, sort_order_plantype
        from non_mh_spend
    )
    select state_fiscal_year as fiscal_year, *
    from combined
    where 1=1
    --and month = ''202207''
    --order by sort_order_demo, sort_order_plantype
    ;

    create or replace view BUDGET_MONTHLY_DEMOBYPLAN as
    select *
    from BUDGET_MONTHLY_DEMOBYPLAN_STG
    ;

	RETURN_STR := RETURN_STR ||  ''Table BUDGET_MONTHLY_DEMOBYPLAN created successfully.'';

    --------------------------------------------------------------------

    -- 22s
    create or replace table BUDGET_MONTHLY_PLANBYDEMO_STG as
    with
    mem_months as (
        select state_fiscal_year, to_char(first_dt_of_month, ''YYYYMM'') as month,
            plantype, demographic,
            sum(members_in_month) as members_in_month
        from BUDGET_MONTHLY_MEMBERMONTH
        group by all
    ),
    mem_spend as (
        select state_fiscal_year, to_char(first_dt_of_month, ''YYYYMM'') as month,
            plantype, demographic,
            sum(amt_paid) as sum_amt_paid,
            sort_order_demo, sort_order_plantype
        from BUDGET_MONTHLY_TRANSACTIONS
        group by all
    ),
    -- 31 rows of Demo x Plan Type
    pmpm as (
        select mm.*,
            ms.sum_amt_paid, ms.sum_amt_paid/mm.members_in_month as pmpm,
            mm.Plantype as pmpm_type, mm.demographic as group_name,
            ms.sort_order_demo, ms.sort_order_plantype
        from mem_months mm
        left join mem_spend ms
            on mm.state_fiscal_year = ms.state_fiscal_year
            and mm.month = ms.month
            and mm.demographic = ms.demographic
            and mm.plantype = ms.plantype 
        where 1=1
    ),
    -- 9 rows of Plan Types
    pmpm_subtotals as (
        select state_fiscal_year, month,
            plantype, ''Total'' as demographic,
            sum(members_in_month) as members_in_month,
            sum(sum_amt_paid) as sum_amt_paid,
            sum(sum_amt_paid) / sum(members_in_month) as pmpm,
            plantype as pmpm_type, ''Total'' as group_name,
            sort_order_plantype, 1000 as sort_order_demo
        from pmpm
        group by all
    ),
    -- 1 row (sum of all spend except MNGO aka Other Capitation)
    pmpm_total as (
        select state_fiscal_year, month,
            ''MassHealth Total'' as plantype, ''Total'' as demographic,
            sum(members_in_month) as members_in_month,
            sum(sum_amt_paid) as sum_amt_paid,
            sum(sum_amt_paid) / sum(members_in_month) as pmpm,
            ''MassHealth Total'' as pmpm_type, ''Total'' as group_name,
            1001 as sort_order_plantype, 1000 as sort_order_demo
        from pmpm
        group by all
    ),
    -- 1 row (Sum of all spend that has associated member months, aka everything but MNGO)
    grand_total_spend as (
        select state_fiscal_year, to_char(first_dt_of_month, ''YYYYMM'') as month,
            ''Grand Total'' as plantype, '''' as demographic,
            0 as members_in_month,
            sum(amt_paid) as sum_amt_paid,
            0 as pmpm,
            ''Grand Total'' as pmpm_type, '''' as group_name,
            1004 as sort_order_plantype, 1004 as sort_order_demo
        from BUDGET_MONTHLY_TRANSACTIONS
        group by all
    ),
    -- 1 row (MNGO, derived as Total - Everything else, to guarantee it ties)
    non_mh_spend as (
        select gt.state_fiscal_year, gt.month,
            ''Non-Member Specifc'' as plantype, '''' as demographic,
            0 as members_in_month,
            gt.sum_amt_paid - pt.sum_amt_paid as sum_amt_paid,
            0 as pmpm,
            ''Non-Member Specifc'' as pmpm_type, '''' as group_name,
            1003 as sort_order_demo, 1003 as sort_order_plantype
        from grand_total_spend gt
        inner join pmpm_total pt
            on  gt.state_fiscal_year = pt.state_fiscal_year
            and gt.month = pt.month
    ),
    combined as (
        select state_fiscal_year, month, members_in_month, sum_amt_paid, pmpm, pmpm_type, group_name, sort_order_demo, sort_order_plantype
        from pmpm
        --
        union all
        --
        select state_fiscal_year, month, members_in_month, sum_amt_paid, pmpm, pmpm_type, group_name, sort_order_demo, sort_order_plantype
        from pmpm_subtotals
        --
        union all
        --
        select state_fiscal_year, month, members_in_month, sum_amt_paid, pmpm, pmpm_type, group_name, sort_order_demo, sort_order_plantype
        from pmpm_total
        --
        union all
        --
        select state_fiscal_year, month, members_in_month, sum_amt_paid, pmpm, pmpm_type, group_name, sort_order_demo, sort_order_plantype
        from grand_total_spend
        --
        union all
        --
        select state_fiscal_year, month, members_in_month, sum_amt_paid, pmpm, pmpm_type, group_name, sort_order_demo, sort_order_plantype
        from non_mh_spend
    )
    select *
    from combined
    where 1=1
    --and month = ''202207''
    --order by sort_order_demo, sort_order_plantype
    ;

    create or replace view BUDGET_MONTHLY_PLANBYDEMO as
    select *
    from BUDGET_MONTHLY_PLANBYDEMO_STG
    ;

	RETURN_STR := RETURN_STR ||  ''Table BUDGET_MONTHLY_PLANBYDEMO created successfully.'';

    --------------------------------------------------------------------

    -- 
    create or replace table BUDGET_MONTHLY_PMPM_DEMOBYPT_STG as
    with
    mem_months as (
        select state_fiscal_year, to_char(first_dt_of_month, ''YYYYMM'') as month,
               demographic,
               sum(members_in_month) as members_in_month
        from BUDGET_MONTHLY_MEMBERMONTH
        group by all
    ),
    mem_spend as (
        select state_fiscal_year, to_char(first_dt_of_month, ''YYYYMM'') as month,
               demographic, provider_category,
               sum(amt_paid) as sum_amt_paid,
            sort_order_demo, sort_order_category
        from BUDGET_MONTHLY_TRANSACTIONS
        group by all
    ),
    -- 31 rows of Plan Type x Demo
    pmpm as (
        select mm.*,
            ms.sum_amt_paid, ms.sum_amt_paid/mm.members_in_month as pmpm,
            mm.demographic as pmpm_type, ms.provider_category as group_name,
            ms.sort_order_category, ms.sort_order_demo
        from mem_months mm
        left join mem_spend ms
            on mm.state_fiscal_year = ms.state_fiscal_year
            and mm.month = ms.month
            and mm.demographic = ms.demographic
        where 1=1
    ),
    -- rows of Demo
    pmpm_subtotals as (
        select state_fiscal_year, month,
            demographic, ''Total'' as provider_category,
            max(members_in_month) as members_in_month, -- demographic not mutually exclusive. same for each category
            sum(sum_amt_paid) as sum_amt_paid,
            sum(sum_amt_paid) / max(members_in_month) as pmpm,
            demographic as pmpm_type, ''Total'' as group_name,
            sort_order_demo, 1000 as sort_order_category
        from pmpm
        group by all
    ),
    -- total membership per month, not broken down by demographic (cuz later aggregation would double count)
    mem_months_total as (
        select state_fiscal_year, to_char(first_dt_of_month, ''YYYYMM'') as month,
            sum(members_in_month) as members_in_month
        from BUDGET_MONTHLY_MEMBERMONTH
        group by all
    ),
    -- 1 row (sum of all spend except MNGO aka Other Capitation)
    pmpm_total as (
        select pmpm.state_fiscal_year, pmpm.month,
            ''MassHealth Total'' as demographic, ''Total'' as provider_category,
            mmt.members_in_month as members_in_month,
            sum(sum_amt_paid) as sum_amt_paid,
            sum(sum_amt_paid) / mmt.members_in_month as pmpm,
            ''MassHealth Total'' as pmpm_type, ''Total'' as group_name,
            1001 as sort_order_demo, 1000 as sort_order_category
        from pmpm
        left join mem_months_total mmt
            on  pmpm.state_fiscal_year = mmt.state_fiscal_year
            and pmpm.month = mmt.month
        group by all
    ),
    -- 1 row (Sum of all spend that has associated member months, aka everything but MNGO)
    grand_total_spend as (
        select state_fiscal_year, to_char(first_dt_of_month, ''YYYYMM'') as month,
            ''Grand Total'' as demographic, '''' as provider_category,
            0 as members_in_month,
            sum(amt_paid) as sum_amt_paid,
            0 as pmpm,
            ''Grand Total'' as pmpm_type, '''' as group_name,
            1004 as sort_order_demo, 1004 as sort_order_category
        from BUDGET_MONTHLY_TRANSACTIONS
        group by all
    ),
    -- 1 row (MNGO, derived as Total - Everything else, to guarantee it ties)
    non_mh_spend as (
        select gt.state_fiscal_year, gt.month,
            ''Non-Member Specifc'' as demographic, '''' as provider_category,
            0 as members_in_month,
            gt.sum_amt_paid - pt.sum_amt_paid as sum_amt_paid,
            0 as pmpm,
            ''Non-Member Specifc'' as pmpm_type, '''' as group_name,
            1003 as sort_order_demo, 1003 as sort_order_category
        from grand_total_spend gt
        inner join pmpm_total pt
            on  gt.state_fiscal_year = pt.state_fiscal_year
            and gt.month = pt.month
    ),
    combined as (
        select state_fiscal_year, month, members_in_month, sum_amt_paid, pmpm, pmpm_type, group_name, sort_order_category, sort_order_demo
        from pmpm
        --
        union all
        --
        select state_fiscal_year, month, members_in_month, sum_amt_paid, pmpm, pmpm_type, group_name, sort_order_category, sort_order_demo
        from pmpm_subtotals
        --
        union all
        --
        select state_fiscal_year, month, members_in_month, sum_amt_paid, pmpm, pmpm_type, group_name, sort_order_category, sort_order_demo
        from pmpm_total
        --
        union all
        --
        select state_fiscal_year, month, members_in_month, sum_amt_paid, pmpm, pmpm_type, group_name, sort_order_category, sort_order_demo
        from grand_total_spend
        --
        union all
        --
        select state_fiscal_year, month, members_in_month, sum_amt_paid, pmpm, pmpm_type, group_name, sort_order_category, sort_order_demo
        from non_mh_spend
    )
    select *
    from combined
    where 1=1
    ;

    create or replace view BUDGET_MONTHLY_PMPM_DEMOBYPT as
    select *
    from BUDGET_MONTHLY_PMPM_DEMOBYPT_STG
    ;

	RETURN_STR := RETURN_STR ||  ''Table BUDGET_MONTHLY_PMPM_DEMOBYPT created successfully.'';

    --------------------------------------------------------------------


    create or replace table BUDGET_MONTHLY_PMPM_PLANBYPT_STG as
    with
    mem_months as (
        select state_fiscal_year, to_char(first_dt_of_month, ''YYYYMM'') as month,
            plantype,
            sum(members_in_month) as members_in_month
        from BUDGET_MONTHLY_MEMBERMONTH
        group by all
    ),
    mem_spend as (
        select state_fiscal_year, to_char(first_dt_of_month, ''YYYYMM'') as month,
            plantype, provider_category,
            sum(amt_paid) as sum_amt_paid,
            sort_order_plantype, sort_order_category
        from BUDGET_MONTHLY_TRANSACTIONS
        group by all
    ),
    -- 31 rows of Plan Type x Demo
    pmpm as (
        select mm.*,
            ms.sum_amt_paid, ms.sum_amt_paid/mm.members_in_month as pmpm,
            mm.Plantype as pmpm_type, ms.provider_category as group_name,
            ms.sort_order_category, ms.sort_order_plantype
        from mem_months mm
        left join mem_spend ms
            on mm.state_fiscal_year = ms.state_fiscal_year
            and mm.month = ms.month
            and mm.plantype = ms.plantype 
        where 1=1
    ),
    -- 9 rows of Plan Types
    pmpm_subtotals as (
        select state_fiscal_year, month,
            plantype, ''Total'' as provider_category,
            max(members_in_month) as members_in_month, -- plantype not mutually exclusive. same for each category
            sum(sum_amt_paid) as sum_amt_paid,
            sum(sum_amt_paid) / max(members_in_month) as pmpm,
            plantype as pmpm_type, ''Total'' as group_name,
            sort_order_plantype, 1000 as sort_order_category
        from pmpm
        group by all
    ),
    -- total membership per month, not broken down by plan type (cuz later aggregation would double count)
    mem_months_total as (
        select state_fiscal_year, to_char(first_dt_of_month, ''YYYYMM'') as month,
            sum(members_in_month) as members_in_month
        from BUDGET_MONTHLY_MEMBERMONTH
        group by all
    ),
    -- 1 row (sum of all spend except MNGO aka Other Capitation)
    pmpm_total as (
        select pmpm.state_fiscal_year, pmpm.month,
            ''MassHealth Total'' as plantype, ''Total'' as provider_category,
            mmt.members_in_month as members_in_month,
            sum(sum_amt_paid) as sum_amt_paid,
            sum(sum_amt_paid) / mmt.members_in_month as pmpm,
            ''MassHealth Total'' as pmpm_type, ''Total'' as group_name,
            1001 as sort_order_plantype, 1000 as sort_order_category
        from pmpm
        left join mem_months_total mmt
            on  pmpm.state_fiscal_year = mmt.state_fiscal_year
            and pmpm.month = mmt.month
        group by all
    ),
    -- 1 row (Sum of all spend that has associated member months, aka everything but MNGO)
    grand_total_spend as (
        select state_fiscal_year, to_char(first_dt_of_month, ''YYYYMM'') as month,
            ''Grand Total'' as plantype, '''' as provider_category,
            0 as members_in_month,
            sum(amt_paid) as sum_amt_paid,
            0 as pmpm,
            ''Grand Total'' as pmpm_type, '''' as group_name,
            1004 as sort_order_plantype, 1004 as sort_order_category
        from BUDGET_MONTHLY_TRANSACTIONS
        group by all
    ),
    -- 1 row (MNGO, derived as Total - Everything else, to guarantee it ties)
    non_mh_spend as (
        select gt.state_fiscal_year, gt.month,
            ''Non-Member Specifc'' as plantype, '''' as provider_category,
            0 as members_in_month,
            gt.sum_amt_paid - pt.sum_amt_paid as sum_amt_paid,
            0 as pmpm,
            ''Non-Member Specifc'' as pmpm_type, '''' as group_name,
            1003 as sort_order_plantype, 1003 as sort_order_category
        from grand_total_spend gt
        inner join pmpm_total pt
            on  gt.state_fiscal_year = pt.state_fiscal_year
            and gt.month = pt.month
    ),
    combined as (
        select state_fiscal_year, month, members_in_month, sum_amt_paid, pmpm, pmpm_type, group_name, sort_order_category, sort_order_plantype
        from pmpm
        --
        union all
        --
        select state_fiscal_year, month, members_in_month, sum_amt_paid, pmpm, pmpm_type, group_name, sort_order_category, sort_order_plantype
        from pmpm_subtotals
        --
        union all
        --
        select state_fiscal_year, month, members_in_month, sum_amt_paid, pmpm, pmpm_type, group_name, sort_order_category, sort_order_plantype
        from pmpm_total
        --
        union all
        --
        select state_fiscal_year, month, members_in_month, sum_amt_paid, pmpm, pmpm_type, group_name, sort_order_category, sort_order_plantype
        from grand_total_spend
        --
        union all
        --
        select state_fiscal_year, month, members_in_month, sum_amt_paid, pmpm, pmpm_type, group_name, sort_order_category, sort_order_plantype
        from non_mh_spend
    )
    select *
    from combined
    where 1=1
    --and month = ''202207''
    --order by sort_order_plantype, sort_order_category
    ;

    create or replace view BUDGET_MONTHLY_PMPM_PLANBYPT as
    select *
    from BUDGET_MONTHLY_PMPM_PLANBYPT_STG
    ;

	RETURN_STR := RETURN_STR ||  ''Table BUDGET_MONTHLY_PMPM_PLANBYPT created successfully.'';

    --------------------------------------------------------------------

    create or replace table BUDGET_MONTHLY_PMPM_STG as
    with
    plantype_mm as (
        select state_fiscal_year, to_char(first_dt_of_month, ''YYYYMM'') as month,
            plantype,
            sum(members_in_month) as members_in_month
        from BUDGET_MONTHLY_MEMBERMONTH
        group by all
    ),
    plantype_spend as (
        select state_fiscal_year, to_char(first_dt_of_month, ''YYYYMM'') as month,
            plantype,
            sum(amt_paid) as sum_amt_paid,
            sort_order_plantype
        from BUDGET_MONTHLY_TRANSACTIONS
        group by all
    ),
    plantype_pmpm as (
        select mm.* exclude members_in_month,
            ''Plan Type'' as pmpm_type, mm.Plantype as group_name,
            mm.members_in_month,
            ms.sum_amt_paid, ms.sum_amt_paid/mm.members_in_month as pmpm,
            ms.sort_order_plantype as sort_order
        from plantype_mm mm
        left join plantype_spend ms
            on mm.state_fiscal_year = ms.state_fiscal_year
            and mm.month = ms.month
            and mm.plantype = ms.plantype 
        where 1=1
    ),
    demo_mm as (
        select state_fiscal_year, to_char(first_dt_of_month, ''YYYYMM'') as month,
            demographic,
            sum(members_in_month) as members_in_month
        from BUDGET_MONTHLY_MEMBERMONTH
        group by all
    ),
    demo_spend as (
        select state_fiscal_year, to_char(first_dt_of_month, ''YYYYMM'') as month,
            demographic,
            sum(amt_paid) as sum_amt_paid,
            sort_order_demo
        from BUDGET_MONTHLY_TRANSACTIONS
        group by all
    ),
    demo_pmpm as (
        select mm.* exclude members_in_month,
            ''Demographic'' as pmpm_type, mm.demographic as group_name,
            mm.members_in_month,
            ms.sum_amt_paid, ms.sum_amt_paid/mm.members_in_month as pmpm,
            ms.sort_order_demo as sort_order
        from demo_mm mm
        left join demo_spend ms
            on mm.state_fiscal_year = ms.state_fiscal_year
            and mm.month = ms.month
            and mm.demographic = ms.demographic 
        where 1=1
    ),
    total_mm as (
        select state_fiscal_year, to_char(first_dt_of_month, ''YYYYMM'') as month,
            sum(members_in_month) as members_in_month
        from BUDGET_MONTHLY_MEMBERMONTH
        group by all
    ),
    total_spend as (
        select state_fiscal_year, to_char(first_dt_of_month, ''YYYYMM'') as month,
            sum(amt_paid) as sum_amt_paid
        from BUDGET_MONTHLY_TRANSACTIONS
        group by all
    ),
    total_pmpm as (
        select mm.* exclude members_in_month,
            ''MassHealth Total'' as pmpm_type, ''Total'' as group_name,
            mm.members_in_month,
            ms.sum_amt_paid, ms.sum_amt_paid/mm.members_in_month as pmpm,
            1000 as sort_order
        from total_mm mm
        left join total_spend ms
            on mm.state_fiscal_year = ms.state_fiscal_year
            and mm.month = ms.month
        where 1=1
    ),
    combined as (
        select state_fiscal_year, month, pmpm_type, group_name, members_in_month, sum_amt_paid, pmpm, sort_order
        from plantype_pmpm
        --
        union all
        --
        select state_fiscal_year, month, pmpm_type, group_name, members_in_month, sum_amt_paid, pmpm, sort_order
        from demo_pmpm
        --
        union all
        --
        select state_fiscal_year, month, pmpm_type, group_name, members_in_month, sum_amt_paid, pmpm, sort_order
        from total_pmpm
    )
    select *
    from combined
    where 1=1
    --and month = ''202207''
    --order by sort_order
    ;

    create or replace view BUDGET_MONTHLY_PMPM as
    select *
    from BUDGET_MONTHLY_PMPM_STG
    ;

	RETURN_STR := RETURN_STR ||  ''Table BUDGET_MONTHLY_PMPM created successfully.'';

    --------------------------------------------------------------------

    create or replace table BUDGET_MONTHLY_PMPM_DEMO_QTR_STG as
    with
    demo_mm as (
        select state_fiscal_year,
               date_trunc(''quarter'', first_dt_of_month - interval ''6 months'') as qtr_sfy,
               demographic,
               sum(members_in_month) as members_in_month,
               count(distinct first_dt_of_month) as num_months
        from BUDGET_MONTHLY_MEMBERMONTH
        group by state_fiscal_year, demographic,
                 date_trunc(''quarter'', first_dt_of_month - interval ''6 months'')
    ),
    demo_spend as (
        select state_fiscal_year,
               date_trunc(''quarter'', first_dt_of_month - interval ''6 months'') as qtr_sfy,
               demographic,
               sum(amt_paid) as sum_amt_paid,
               sort_order_demo
        from BUDGET_MONTHLY_TRANSACTIONS
        where source in (''FFS'', ''MNGC'')
        group by state_fiscal_year, demographic, SORT_ORDER_DEMO,
                 date_trunc(''quarter'', first_dt_of_month - interval ''6 months'')
    ),
    demo_pmpm as (
        select mm.* exclude members_in_month,
            mm.demographic as group_name,
            mm.members_in_month / mm.num_months as members_in_month,
            ms.sum_amt_paid,
            ms.sum_amt_paid/(mm.members_in_month) as pmpm_qtr,
            ms.sort_order_demo as sort_order
        from demo_mm mm
        left join demo_spend ms
            on mm.state_fiscal_year = ms.state_fiscal_year
            and mm.qtr_sfy = ms.qtr_sfy
            and mm.demographic = ms.demographic 
        where 1=1
    ),
    total_pmpm as (
        select state_fiscal_year, qtr_sfy,
            ''Total'' as demographic,
            sum(d.sum_amt_paid) as sum_amt_paid,
            sum(d.members_in_month) as members_in_month,
            sum(d.sum_amt_paid) / sum(d.members_in_month*d.num_months) as pmpm_qtr,
            1000 as sort_order
        from demo_pmpm d
        group by state_fiscal_year, qtr_sfy
    ),
    combined as (
        select state_fiscal_year, qtr_sfy, demographic, sum_amt_paid, members_in_month, pmpm_qtr, sort_order
        from demo_pmpm
        --
        union all
        --
        select state_fiscal_year, qtr_sfy, demographic, sum_amt_paid, members_in_month, pmpm_qtr, sort_order
        from total_pmpm
    ),
    CTE AS (
        SELECT state_fiscal_year, qtr_sfy, demographic, sum_amt_paid, members_in_month, pmpm_qtr,
                sort_order,
                LAG(sum_amt_paid)     OVER (PARTITION BY demographic ORDER BY qtr_sfy) AS lag_sum_amt_paid,
                LAG(pmpm_qtr)         OVER (PARTITION BY demographic ORDER BY qtr_sfy) AS lag_pmpm_qtr,
                LAG(members_in_month) OVER (PARTITION BY demographic ORDER BY qtr_sfy) AS lag_members_in_month,
                ROW_NUMBER()          OVER (PARTITION BY demographic ORDER BY qtr_sfy) AS row_no
        FROM combined
    )
    SELECT state_fiscal_year, qtr_sfy, demographic, sum_amt_paid, members_in_month, pmpm_qtr, sort_order,
            CASE WHEN row_no = 1 OR lag_sum_amt_paid     = 0 THEN 0 ELSE (sum_amt_paid     / lag_sum_amt_paid)     - 1 END AS trend_spending,
            CASE WHEN row_no = 1 OR lag_pmpm_qtr         = 0 THEN 0 ELSE (pmpm_qtr         / lag_pmpm_qtr)         - 1 END AS trend_pmpm,
            CASE WHEN row_no = 1 OR lag_members_in_month = 0 THEN 0 ELSE (members_in_month / lag_members_in_month) - 1 END AS trend_membership
    FROM CTE
    where 1=1
    --and qtr_sfy = ''2022-07-01''
    --order by sort_order
    ;

    create or replace view BUDGET_MONTHLY_PMPM_DEMO_QTR as
    select *, sort_order as order1
    from BUDGET_MONTHLY_PMPM_DEMO_QTR_STG
    ;

	RETURN_STR := RETURN_STR ||  ''Table BUDGET_MONTHLY_PMPM_DEMO_QTR created successfully.'';


    --------------------------------------------------------------------

    create or replace table BUDGET_MONTHLY_PMPM_PLAN_QTR_STG as
    with
    demo_mm as (
        select state_fiscal_year,
               date_trunc(''quarter'', first_dt_of_month - interval ''6 months'') as qtr_sfy,
               plantype,
               sum(members_in_month) as members_in_month,
               count(distinct first_dt_of_month) as num_months
        from BUDGET_MONTHLY_MEMBERMONTH
        group by state_fiscal_year, plantype,
                 date_trunc(''quarter'', first_dt_of_month - interval ''6 months'')
    ),
    demo_spend as (
        select state_fiscal_year,
               date_trunc(''quarter'', first_dt_of_month - interval ''6 months'') as qtr_sfy,
               plantype,
               sum(amt_paid) as sum_amt_paid,
               sort_order_plantype
        from BUDGET_MONTHLY_TRANSACTIONS
        where source in (''FFS'', ''MNGC'')
        group by state_fiscal_year, plantype, SORT_ORDER_PLANTYPE,
                 date_trunc(''quarter'', first_dt_of_month - interval ''6 months'')
    ),
    demo_pmpm as (
        select mm.* exclude members_in_month,
            mm.members_in_month / mm.num_months as members_in_month,
            ms.sum_amt_paid, ms.sum_amt_paid/(mm.members_in_month) as pmpm_qtr,
            ms.sort_order_plantype as sort_order
        from demo_mm mm
        left join demo_spend ms
            on mm.state_fiscal_year = ms.state_fiscal_year
            and mm.qtr_sfy = ms.qtr_sfy
            and mm.plantype = ms.plantype 
        where 1=1
    ),
    total_pmpm as (
        select state_fiscal_year, qtr_sfy,
            ''Total'' as plantype,
            sum(d.sum_amt_paid) as sum_amt_paid,
            sum(d.members_in_month) as members_in_month,
            sum(d.sum_amt_paid) / sum(d.members_in_month*d.num_months) as pmpm_qtr,
            1000 as sort_order
        from demo_pmpm d
        group by state_fiscal_year, qtr_sfy
    ),
    combined as (
        select state_fiscal_year, qtr_sfy, plantype, sum_amt_paid, members_in_month, pmpm_qtr, sort_order
        from demo_pmpm
        --
        union all
        --
        select state_fiscal_year, qtr_sfy, plantype, sum_amt_paid, members_in_month, pmpm_qtr, sort_order
        from total_pmpm
    ),
    CTE AS (
        SELECT state_fiscal_year, qtr_sfy, plantype, sum_amt_paid, members_in_month, pmpm_qtr,
                sort_order,
                LAG(sum_amt_paid)     OVER (PARTITION BY plantype ORDER BY qtr_sfy) AS lag_sum_amt_paid,
                LAG(pmpm_qtr)         OVER (PARTITION BY plantype ORDER BY qtr_sfy) AS lag_pmpm_qtr,
                LAG(members_in_month) OVER (PARTITION BY plantype ORDER BY qtr_sfy) AS lag_members_in_month,
                ROW_NUMBER()          OVER (PARTITION BY plantype ORDER BY qtr_sfy) AS row_no
        FROM combined
    )
    SELECT state_fiscal_year, qtr_sfy, plantype, sum_amt_paid, members_in_month, pmpm_qtr, sort_order,
            CASE WHEN row_no = 1 OR lag_sum_amt_paid     = 0 THEN 0 ELSE (sum_amt_paid     / lag_sum_amt_paid)     - 1 END AS trend_spending,
            CASE WHEN row_no = 1 OR lag_pmpm_qtr         = 0 THEN 0 ELSE (pmpm_qtr         / lag_pmpm_qtr)         - 1 END AS trend_pmpm,
            CASE WHEN row_no = 1 OR lag_members_in_month = 0 THEN 0 ELSE (members_in_month / lag_members_in_month) - 1 END AS trend_membership
    FROM CTE
    where 1=1
    --and qtr_sfy = ''2022-07-01''
    --order by sort_order
    ;

    create or replace view BUDGET_MONTHLY_PMPM_PLAN_QTR as
    select *, sort_order as order1
    from BUDGET_MONTHLY_PMPM_PLAN_QTR_STG
    ;

	RETURN_STR := RETURN_STR ||  ''Table BUDGET_MONTHLY_PMPM_PLAN_QTR created successfully.'';

    --------------------------------------------------------------------

    RETURN RETURN_STR;
END;
';


call MHTEAM.MHA.BUDGET_MONTHLY_REWRITE_P5_PMPM_MEASURES();



-------------------------------------------------------




/*======================================================================
  PROCEDURE 6: BUDGET_MONTHLY_REWRITE_P6_LTM
  PURPOSE:
    Creates the Last Twelve Months (LTM), fiscal-year rollups, variance
    tables, and frozen monthly LTM snapshot history used by the Budget
    dashboard.

  MAIN WORK:
    - Determines the latest available reporting month dynamically.
    - Builds the most recent 12-month transaction window.
    - Creates provider category/group LTM totals.
    - Creates historical closed-fiscal-year rollups.
    - Calculates FY-to-FY and latest-FY-to-LTM variances.
    - Appends only missing snapshot months into LTM snapshot history.

  MAIN OUTPUTS / VIEWS:
    - BUDGET_MONTHLY_LAST_MONTH
    - BUDGET_MONTHLY_LTM_DETAILS
    - BUDGET_MONTHLY_LTM_ROLLUP
    - BUDGET_MONTHLY_LTM_STAGE
    - BUDGET_MONTHLY_LTM
    - BUDGET_MONTHLY_VARIANCE
    - MHTEAM.MHA.BUDGET_MONTHLY_LTM_SNAPSHOT_HIST

  DEPENDENCY:
    - P2 BUDGET_MONTHLY_TRANSACTIONS

  NEXT STEP:
    ROLL_FORWARD_LTM_PATCH_TABLE compares current LTM to the prior
    frozen monthly LTM snapshot and publishes the Tableau patch table.
======================================================================*/
CREATE OR REPLACE PROCEDURE MHTEAM.MHA.BUDGET_MONTHLY_REWRITE_P6_LTM()
RETURNS VARCHAR(16777216)
LANGUAGE SQL
EXECUTE AS CALLER
AS '
DECLARE

    RETURN_STR STRING := '''';
BEGIN

    create or replace table BUDGET_MONTHLY_LAST_MONTH_STG as
    with
    start_end_months as (
        select max(to_char(first_dt_of_month, ''YYYYMM'')) as max_m,
                to_varchar(DATEADD(MONTH, -11, to_date(max_m||''01'',''YYYYMMDD'')), ''YYYYMM'') as ltm
        from BUDGET_MONTHLY_TRANSACTIONS
    ),
    ltm_transactions as (
        select *
        from BUDGET_MONTHLY_TRANSACTIONS a, start_end_months sem
        where to_char(first_dt_of_month, ''YYYYMM'') >= sem.ltm
    ),
    ffs_sort_order as (
        select max(sort_order_category) as max_ffs_sort_order
        from ltm_transactions
        where provider_category <> ''Capitation''
    )
    -- group level
    select provider_category,
           provider_group,
           rp_typ_char_cd,
           sort_order_category as order_group,
           sort_order_group as order_report,
           sum(amt_paid) as sum_amt_paid
    from  ltm_transactions
    group by all
    --
    union all
    --
    -- Total per Category
    select provider_category,
           ''Total '' || provider_category as provider_group,
           rp_typ_char_cd,
           sort_order_category as order_group,
           1000 as order_report,
           sum(amt_paid) as sum_amt_paid
    from  ltm_transactions
    group by all
    --
    union all
    --
    -- Total FFS
    select ''Total Fee For Service Spend'' as provider_category,
           '''' as provider_group,
           rp_typ_char_cd,
           max_ffs_sort_order+0.1 as order_group,
           1000 as order_report,
           sum(amt_paid) as sum_amt_paid
    from  ltm_transactions, ffs_sort_order
    where provider_category <> ''Capitation''
    group by all
    --
    union all
    --
    -- All spend
    select ''Programmatic Spend'' as provider_category,
           ''Total FFS + Capitation'' as provider_group,
           rp_typ_char_cd,
           1000 as order_group,
           1000 as order_report,
           sum(amt_paid) as sum_amt_paid
    from  ltm_transactions
    group by all
    order by order_group, order_report
    ;

    create or replace view BUDGET_MONTHLY_LAST_MONTH as
    select *
    from BUDGET_MONTHLY_LAST_MONTH_STG
    ;
 
	RETURN_STR := RETURN_STR ||  ''Table BUDGET_MONTHLY_LAST_MONTH created successfully.'';


    create or replace table budget_monthly_ltm_details as
    with
    -- Determine the last month and last twelve months (LTM) fiscal year
    cte_m as (
    select
            max(to_char(first_dt_of_month, ''YYYYMM'')) as max_m,
            to_varchar(
                DATEADD(
                    MONTH,
                    -11,
                    to_date(max(to_char(first_dt_of_month, ''YYYYMM'')) || ''01'', ''YYYYMMDD'')
                ),
                ''YYYYMM''
            ) as ltm,
            max(state_fiscal_year) as ltm_year
        from BUDGET_MONTHLY_TRANSACTIONS
    )
    -- Summarizes all data before the last fiscal year, grouped by fiscal year (eg 202207 -> month=''202306'' cuz SFY).
    select state_fiscal_year,
           state_fiscal_year||''06'' as month,
           provider_category as provider_category_,
           provider_group as provider_group_,
           rp_typ_char_cd,
           sort_order_category as order_group,
           sort_order_group as order_report,
           sum(amt_paid) as sum_amt_paid
    from  BUDGET_MONTHLY_TRANSACTIONS
    cross join cte_m
    where state_fiscal_year < cte_m.ltm_year
    group by all
    --
    union all
    --
    -- Summarizes the most recent 12 months as a single period, regardless of fiscal year.
    select cte_m.ltm_year as state_fiscal_year,
           cte_m.max_m as month,
           provider_category as provider_category_,
           provider_group as provider_group_,
           rp_typ_char_cd,
           sort_order_category as order_group,
           sort_order_group as order_report,
           sum(amt_paid) as sum_amt_paid
    from BUDGET_MONTHLY_TRANSACTIONS
    cross join cte_m
    where to_char(first_dt_of_month, ''YYYYMM'') >= cte_m.ltm -- grabs all 12 months who are >= the LTM month
    group by all
    ;

	RETURN_STR := RETURN_STR ||  ''budget_monthly_ltm_details completed successfully.'';

    create or replace table budget_monthly_ltm_rollup as
    with
    ffs_sort_order as (
        select max(order_group) as max_ffs_sort_order
        from budget_monthly_ltm_details
        where provider_category_ <> ''Capitation''
    )
    select state_fiscal_year, month, provider_category_ as provider_category,
           rp_typ_char_cd,
           provider_group_ as provider_group,
           order_group, order_report,
           sum_amt_paid
    from budget_monthly_ltm_details
    --
    union all
    --
    select state_fiscal_year, month, provider_category_ as provider_category,
           rp_typ_char_cd,
            case
                    when provider_category = ''Physical Health (FFS)''        then ''Total Physical Health''
                    when provider_category = ''Behavioral Health (FFS)''      then ''Total Behavioral Health''
                    when provider_category = ''Hospital (FFS)''               then ''Total Hospital''
                    when provider_category = ''Community LTSS''               then ''Total Community LTSS''
                    when provider_category = ''Institutional LTSS''           then ''Total Institutional LTSS''
                    when provider_category = ''FFS Other - Medicare Xover''   then ''Total FFS Other - Medicare Xover''
                    when provider_category = ''FFS Other - Special Programs'' then ''Total FFS Other - Special Programs''
                    when provider_category = ''FFS Other - Other''            then ''Total FFS Other - Other''
                    when provider_category = ''Capitation''                   then ''Total Capitation''
            end as provider_group,
            order_group,
            1000 as order_report,
            sum(sum_amt_paid) as sum_amt_paid
    from budget_monthly_ltm_details
    group by all
    --
    union all
    --
    select state_fiscal_year, month,
        ''Total Fee For Service Spend'' as provider_category,
        rp_typ_char_cd,
        '''' as provider_group,
        max_ffs_sort_order+0.1 as order_group,
        1000 as order_report,
        sum(sum_amt_paid) as sum_amt_paid
    from budget_monthly_ltm_details ltm, ffs_sort_order
    where ltm.provider_category_ in (''Behavioral Health (FFS)'', ''Community LTSS'', ''Hospital (FFS)'',
                                     ''Institutional LTSS'', ''Other FFS'', ''Physical Health (FFS)'')
    group by all
    --
    union all
    --
    select state_fiscal_year, month,
        ''Programmatic Spend'' as provider_category,
        rp_typ_char_cd,
        ''Total FFS + Capitation'' as provider_group,
        1000 as order_group,
        1000 as order_report,
        sum(sum_amt_paid) as sum_amt_paid
    from budget_monthly_ltm_details ltm
    group by all
    ;

	RETURN_STR := RETURN_STR ||  ''budget_monthly_ltm_rollup completed successfully.'';


    create or replace table budget_monthly_ltm_stage as
    select month, 
            to_date(concat(substr(month,1,4), ''-'', substr(month,5,2), ''-01''), ''YYYY-MM-DD'') as first_date,
            to_char(DATEADD(DAY, -1, DATE_TRUNC(MONTH,first_date)+ INTERVAL ''1 MONTH''), ''MON DD, YYYY'') as last_date,
            provider_category, provider_group,
            RP_TYP_CHAR_CD,
            order_group, order_report,
            sum_amt_paid
    from budget_monthly_ltm_rollup;

    create or replace view budget_monthly_ltm as
    select *
    from budget_monthly_ltm_stage;

	RETURN_STR := RETURN_STR ||  ''budget_monthly_ltm completed successfully.'';

    --------------------------------------------------------------------
    
    create or replace table budget_monthly_variance_stg as
    with
    -- single row (eg 202601	202502	2026	2016)
    cte_m as (
        select
            max(to_char(first_dt_of_month, ''YYYYMM'')) as max_m,
            to_varchar(
                dateadd(month, -11, to_date(max(to_char(first_dt_of_month, ''YYYYMM'')) || ''01'', ''YYYYMMDD'')),
                ''YYYYMM''
            ) as ltm,
            max(state_fiscal_year) as ltm_year,
            min(state_fiscal_year) as min_year
        from budget_monthly_transactions
    ),
    --------------------------------------------------------------------
    -- Closed FY to next closed FY variance
    --------------------------------------------------------------------    
    fy_base as (
        select
            state_fiscal_year,
            provider_category,
            provider_group,
            order_group,
            order_report,
            lpad(trim(coalesce(rp_typ_char_cd, '''')), 2, ''0'') as rp_typ_char_cd,
            sum(sum_amt_paid) as sum_amt_paid
        from budget_monthly_ltm_rollup
        --where provider_group not like ''Total %''
        group by 1,2,3,4,5,6
    ),

    fy_to_fy as (
        select
            coalesce(a.provider_category, b.provider_category) as provider_category,
            coalesce(a.provider_group, b.provider_group) as provider_group,
            coalesce(a.rp_typ_char_cd, b.rp_typ_char_cd) as rp_typ_char_cd,
            coalesce(a.state_fiscal_year, b.state_fiscal_year - 1) as current_fy,
            coalesce(b.state_fiscal_year, a.state_fiscal_year + 1) as next_fy,
            coalesce(a.order_group, b.order_group) as order_group,
            coalesce(a.order_report, b.order_report) as order_report,
            coalesce(b.sum_amt_paid, 0) - coalesce(a.sum_amt_paid, 0) as variance,
            coalesce(a.sum_amt_paid, 0) as previous_amount
        from (
            select *
            from fy_base
            where state_fiscal_year < (select ltm_year from cte_m)
        ) a
        full outer join (
            select *
            from fy_base
            where state_fiscal_year > (select min_year from cte_m)
            and state_fiscal_year < (select ltm_year from cte_m)
        ) b
            on a.provider_category = b.provider_category
        and a.rp_typ_char_cd = b.rp_typ_char_cd
        and coalesce(a.provider_group, '''') = coalesce(b.provider_group, '''')
        and a.state_fiscal_year = b.state_fiscal_year - 1
        where coalesce(a.state_fiscal_year, b.state_fiscal_year - 1)
            < (select ltm_year - 1 from cte_m)
    ),
    --------------------------------------------------------------------
    -- Last closed FY to current LTM variance
    --------------------------------------------------------------------
    fy_to_ltm as (
        select
            coalesce(a.provider_category, b.provider_category) as provider_category,
            coalesce(a.provider_group, b.provider_group) as provider_group,
            coalesce(a.rp_typ_char_cd, b.rp_typ_char_cd) as rp_typ_char_cd,
            coalesce(a.state_fiscal_year, b.state_fiscal_year - 1) as current_fy,
            coalesce(b.state_fiscal_year, a.state_fiscal_year + 1) as next_fy,
            coalesce(a.order_group, b.order_group) as order_group,
            coalesce(a.order_report, b.order_report) as order_report,
            coalesce(b.sum_amt_paid, 0) - coalesce(a.sum_amt_paid, 0) as variance,
            coalesce(a.sum_amt_paid, 0) as previous_amount
        from (
            select *
            from fy_base
            where state_fiscal_year = (select ltm_year - 1 from cte_m)
        ) a
        full outer join (
            select *
            from fy_base
            where state_fiscal_year = (select ltm_year from cte_m)
        ) b
            on a.provider_category = b.provider_category
        and a.rp_typ_char_cd = b.rp_typ_char_cd
        and coalesce(a.provider_group, '''') = coalesce(b.provider_group, '''')
    )
    select
        ''FY'' || right(current_fy::varchar, 2) || ''-FY'' || right(next_fy::varchar, 2) as fiscal_year,
        provider_category,
        provider_group,
        rp_typ_char_cd,
        order_group,
        order_report,
        variance,
        previous_amount
    from fy_to_fy
    --
    union all
    --
    select
        ''FY'' || right(current_fy::varchar, 2) || ''-LTM'' || right(current_fy::varchar, 2) as fiscal_year,
        provider_category,
        provider_group,
        rp_typ_char_cd,
        order_group,
        order_report,
        variance,
        previous_amount
    from fy_to_ltm
    --
    order by fiscal_year, provider_category, provider_group, rp_typ_char_cd
    ;

    create or replace view budget_monthly_variance as
    select *
    from budget_monthly_variance_stg
    ;

	RETURN_STR := RETURN_STR ||  ''budget_monthly_variance completed successfully.'';

    --------------------------------------------------------------------

    --    3) BACKFILL / APPEND missing snapshot months only
    --    - preserves existing frozen history
    --    - fills gaps such as 202511, 202512, 202601
    --    - snapshot grain = month + provider_category + provider_group
    MERGE INTO MHTEAM.MHA.BUDGET_MONTHLY_LTM_SNAPSHOT_HIST tgt
    USING (
        SELECT
        s.month AS snapshot_month,
        s.provider_category,
        s.provider_group,
        SUM(s.sum_amt_paid) AS ltm_amount
        FROM MHTEAM.MHA.BUDGET_MONTHLY_LTM_STAGE s
        GROUP BY
        s.month,
        s.provider_category,
        s.provider_group
    ) src
        ON tgt.snapshot_month    = src.snapshot_month
    AND tgt.provider_category = src.provider_category
    AND tgt.provider_group    = src.provider_group
    WHEN NOT MATCHED THEN
        INSERT (
        snapshot_month,
        provider_category,
        provider_group,
        ltm_amount
        )
        VALUES (
        src.snapshot_month,
        src.provider_category,
        src.provider_group,
        src.ltm_amount
        )
    ;

    --------------------------------------------------------------------

    RETURN RETURN_STR;

END;
';


CALL MHTEAM.MHA.BUDGET_MONTHLY_REWRITE_P6_LTM();




/*======================================================================
  FINAL PROCEDURE: ROLL_FORWARD_LTM_PATCH_TABLE
  PURPOSE:
    Rolls the LTM comparison forward automatically each month and
    refreshes the legacy Tableau patch table without changing its name.

  DATE / MONTH LOGIC:
    - Current month is read dynamically from BUDGET_MONTHLY_LTM_STAGE.
    - Prior month is calculated as current month minus one month.
    - No manual month update is required.

  MAIN WORK:
    - Reads the prior frozen LTM baseline from
      BUDGET_MONTHLY_LTM_SNAPSHOT_HIST.
    - Reads the current LTM from BUDGET_MONTHLY_LTM_STAGE.
    - Normalizes blank provider_group values for Total Fee For Service Spend.
    - Calculates amount and percentage variance.
    - Truncates and reloads the Tableau-facing final patch table.
    - Rebuilds the matching current-month rows in patch history so reruns
      are idempotent.

  MAIN OUTPUTS:
    - MHTEAM.MHA.BUDGET_LTM_DOS_SPEND_PATCH_202510_FINAL
    - MHTEAM.MHA.BUDGET_LTM_PATCH_HIST

  DEPENDENCIES:
    - P6 BUDGET_MONTHLY_LTM_STAGE
    - P6 BUDGET_MONTHLY_LTM_SNAPSHOT_HIST

  AUTOMATION NOTE:
    This is the final step after P1 through P6.
======================================================================*/
CREATE OR REPLACE PROCEDURE MHTEAM.MHA.ROLL_FORWARD_LTM_PATCH_TABLE()
RETURNS VARCHAR
LANGUAGE SQL
EXECUTE AS CALLER
AS '
DECLARE
  v_curr_month STRING;   -- current published month from stage
  v_prev_month STRING;   -- prior baseline month = curr_month - 1
  v_prev_rows  NUMBER;
BEGIN

  /*------------------------------------------------------------
    1) Current month from stage
  ------------------------------------------------------------*/
  SELECT MAX(month) INTO :v_curr_month
  FROM MHTEAM.MHA.BUDGET_MONTHLY_LTM_STAGE
  ;

  IF (v_curr_month IS NULL) THEN
    RETURN ''ROLL_FORWARD_LTM_PATCH_TABLE aborted: BUDGET_MONTHLY_LTM_STAGE is empty.'';
  END IF;

  /*------------------------------------------------------------
    2) Prior baseline month = current month - 1
  ------------------------------------------------------------*/
  SELECT TO_VARCHAR(
           DATEADD(MONTH, -1, TO_DATE(:v_curr_month || ''01'', ''YYYYMMDD'')),
           ''YYYYMM''
         )
    INTO :v_prev_month
  ;

  /*------------------------------------------------------------
    3) Build PREV baseline from frozen snapshot history
       IMPORTANT: normalize blank provider_group for
       Total Fee For Service Spend to match current side
  ------------------------------------------------------------*/
  CREATE OR REPLACE TEMP TABLE prev_backup AS
  SELECT
    provider_category AS PROVIDER_CATEGORY,
    CASE
      WHEN provider_category = ''Total Fee For Service Spend''
       AND (provider_group IS NULL OR TRIM(provider_group) = '''')
      THEN ''Total Fee For Service Spend''
      ELSE provider_group
    END AS PROVIDER_GROUP,
    CAST(SUM(ltm_amount) AS NUMBER(38,2)) AS LTM_PREV
  FROM MHTEAM.MHA.BUDGET_MONTHLY_LTM_SNAPSHOT_HIST
  WHERE snapshot_month = :v_prev_month
  GROUP BY
    provider_category,
    CASE
      WHEN provider_category = ''Total Fee For Service Spend''
       AND (provider_group IS NULL OR TRIM(provider_group) = '''')
      THEN ''Total Fee For Service Spend''
      ELSE provider_group
    END
  ;

  SELECT COUNT(*) INTO :v_prev_rows
  FROM prev_backup
  ;

  IF (v_prev_rows = 0) THEN
    RETURN ''ROLL_FORWARD_LTM_PATCH_TABLE aborted: no rows found in MHTEAM.MHA.BUDGET_MONTHLY_LTM_SNAPSHOT_HIST for prev_month='' || v_prev_month;
  END IF;

  /*------------------------------------------------------------
    4) Build CURR from stage (category + group grain)
       IMPORTANT: apply same normalization here
  ------------------------------------------------------------*/
  CREATE OR REPLACE TEMP TABLE curr_new AS
  SELECT
    provider_category AS PROVIDER_CATEGORY,
    CASE
      WHEN provider_category = ''Total Fee For Service Spend''
       AND (provider_group IS NULL OR TRIM(provider_group) = '''')
      THEN ''Total Fee For Service Spend''
      ELSE provider_group
    END AS PROVIDER_GROUP,
    CAST(SUM(sum_amt_paid) AS NUMBER(38,2)) AS LTM_CURR
  FROM MHTEAM.MHA.BUDGET_MONTHLY_LTM_STAGE
  WHERE month = :v_curr_month
  GROUP BY
    provider_category,
    CASE
      WHEN provider_category = ''Total Fee For Service Spend''
       AND (provider_group IS NULL OR TRIM(provider_group) = '''')
      THEN ''Total Fee For Service Spend''
      ELSE provider_group
    END
  ;

  /*------------------------------------------------------------
    5) Publish Tableau FINAL table
       NOTE: keeping legacy table name so Tableau does not break
  ------------------------------------------------------------*/
  TRUNCATE TABLE MHTEAM.MHA.BUDGET_LTM_DOS_SPEND_PATCH_202510_FINAL
  ;

  INSERT INTO MHTEAM.MHA.BUDGET_LTM_DOS_SPEND_PATCH_202510_FINAL
  (
    PROVIDER_CATEGORY,
    PROVIDER_GROUP,
    LTM_PREV,
    LTM_CURR,
    VARIANCE_AMT,
    VARIANCE_PCT
  )
  SELECT
    c.PROVIDER_CATEGORY,
    c.PROVIDER_GROUP,
    CAST(COALESCE(p.LTM_PREV, 0) AS NUMBER(38,2)) AS LTM_PREV,
    CAST(c.LTM_CURR AS NUMBER(38,2)) AS LTM_CURR,
    CAST(c.LTM_CURR - COALESCE(p.LTM_PREV, 0) AS NUMBER(38,2)) AS VARIANCE_AMT,
    CASE
      WHEN COALESCE(p.LTM_PREV, 0) = 0 THEN NULL
      ELSE (c.LTM_CURR - p.LTM_PREV) / p.LTM_PREV
    END AS VARIANCE_PCT
  FROM curr_new c
  LEFT JOIN prev_backup p
    ON p.PROVIDER_CATEGORY = c.PROVIDER_CATEGORY
   AND p.PROVIDER_GROUP    = c.PROVIDER_GROUP
  ;

  /*------------------------------------------------------------
    6) Refresh patch history for this curr_month
       Make procedure idempotent: delete then reinsert
  ------------------------------------------------------------*/
  DELETE FROM MHTEAM.MHA.BUDGET_LTM_PATCH_HIST
  WHERE curr_month = :v_curr_month
  ;

  INSERT INTO MHTEAM.MHA.BUDGET_LTM_PATCH_HIST
  (
    RUN_TS,
    PREV_MONTH,
    CURR_MONTH,
    PROVIDER_CATEGORY,
    PROVIDER_GROUP,
    LTM_PREV,
    LTM_CURR,
    VARIANCE_AMT,
    VARIANCE_PCT
  )
  SELECT
    CURRENT_TIMESTAMP(),
    :v_prev_month,
    :v_curr_month,
    PROVIDER_CATEGORY,
    PROVIDER_GROUP,
    LTM_PREV,
    LTM_CURR,
    VARIANCE_AMT,
    VARIANCE_PCT
  FROM MHTEAM.MHA.BUDGET_LTM_DOS_SPEND_PATCH_202510_FINAL
  ;

  RETURN
    ''ROLL_FORWARD_LTM_PATCH_TABLE complete. prev_month='' || v_prev_month ||
    ''; curr_month='' || v_curr_month ||
    ''; prev_rows='' || v_prev_rows
  ;

END;
';

CALL MHTEAM.MHA.ROLL_FORWARD_LTM_PATCH_TABLE();



-- Capture end time
SET end_time = CURRENT_TIMESTAMP();

/*
Runs:
 - 2026-05-08: 31m 57s
*/

-- Calculate duration in seconds
SELECT
TO_VARCHAR(FLOOR(DATEDIFF('second', $start_time, $end_time) / 60)) || ' min ' ||
TO_VARCHAR(MOD(DATEDIFF('second', $start_time, $end_time), 60)) || ' sec'
AS elapsed_time
;