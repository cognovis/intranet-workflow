SELECT acs_log__debug('/packages/intranet-workflow/sql/postgresql/upgrade/upgrade-4.0.5.0.3-4.0.5.0.4.sql','');

create or replace function im_workflow__assign_to_vacation_replacement_if(
    p_task_id           integer,
    p_case_id           integer,
    p_person_id         integer,
    p_transition_key    varchar,
    p_creation_user     integer,
    p_creation_ip       varchar,
    p_object_type       varchar
)
returns void as
$$
declare
    v_vacation_replacement_id   integer;
    v_vacation_replacement_name varchar;
    v_journal_id                integer;
    v_slack_time_days           integer;
begin

    select attr_value into v_slack_time_days
    from apm_parameter_values pv
    inner join apm_packages pkg
    on (pkg.package_id=pv.package_id)
    inner join apm_parameters p
    on (p.parameter_id=pv.parameter_id)
    where pkg.package_key='intranet-timesheet2' and p.parameter_name='TimesheetSlackTimeDays';

    if v_slack_time_days is null then
        raise exception 'intranet-timesheet2/TimesheetSlackTimeDays parameter must be a number';
    end if;

    -- check if the supervisor_id found is currently on vacation 
    -- (quick query in im_user_absences if now is in between absence dates)

    select vacation_replacement_id, person__name(vacation_replacement_id) 
    into v_vacation_replacement_id, v_vacation_replacement_name
    from im_user_absences
    where owner_id = p_person_id
    and (now() between (start_date - (v_slack_time_days || ' days')::interval) and end_date);

    -- In case an absence is found, check if there is a vacation_replacement_id. 

    if v_vacation_replacement_id is not null then

        -- If there is, assign the workflow to both the supervisor_id and the 
        -- vacation_replacement_id. Record this additional assigning in the 
        -- workflow journal as well.

        v_journal_id := journal_entry__new(
            null, 
            p_case_id,
            p_transition_key || ' assign_to_supervisor ' || v_vacation_replacement_name,
            p_transition_key || ' assign_to_supervisor ' || v_vacation_replacement_name,
            now(), 
            p_creation_user, 
            p_creation_ip,
            'Assigning to ' || v_vacation_replacement_name || ', the vacation replacement of ' || person__name(p_person_id) || '.'
        );

        perform workflow_case__add_task_assignment(p_task_id, v_vacation_replacement_id, 'f');

        perform workflow_case__notify_assignee (p_task_id, v_vacation_replacement_id, null, null, 
            'wf_' || p_object_type || '_assignment_notif');
        
    end if;
end;
$$ language 'plpgsql';
