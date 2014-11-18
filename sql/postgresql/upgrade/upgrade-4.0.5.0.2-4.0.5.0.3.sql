SELECT acs_log__debug('/packages/intranet-workflow/sql/postgresql/upgrade/upgrade-4.0.5.0.2-4.0.5.0.3.sql','');

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
begin

    -- check if the supervisor_id found is currently on vacation 
    -- (quick query in im_user_absences if now is in between absence dates)

    select vacation_replacement_id, person__name(vacation_replacement_id) 
    into v_vacation_replacement_id, v_vacation_replacement_name
    from im_user_absences
    where owner_id = p_person_id
    and (now() between start_date and end_date);

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

-- Unassigned callback that assigns the transition to the supervisor of the owner
-- of the underlying object
--
create or replace function im_workflow__assign_to_supervisor (integer, text)
returns integer as '
declare
	p_task_id		            alias for $1;
	p_custom_arg		        alias for $2;

	v_case_id		            integer;		
    v_object_id	            	integer;
	v_creation_user		        integer;
    v_creation_ip		        varchar;
	v_journal_id		        integer;
    v_object_type		        varchar;
	v_owner_id		            integer;
	v_owner_name		        varchar;
	v_supervisor_id		        integer;
	v_supervisor_name	        varchar;
    v_vacation_replacement_id   integer;
    v_vacation_replacement_name varchar;
	v_transition_key	        varchar;
	v_str			            text;
	row			                record;
begin
	-- Get information about the transition and the "environment"
	select	tr.transition_key, t.case_id, c.object_id, o.creation_user, o.creation_ip, o.object_type
	into	v_transition_key, v_case_id, v_object_id, v_creation_user, v_creation_ip, v_object_type
	from	wf_tasks t, wf_cases c, wf_transitions tr, acs_objects o
	where	t.task_id = p_task_id
		and t.case_id = c.case_id
		and o.object_id = t.case_id
		and t.workflow_key = tr.workflow_key
		and t.transition_key = tr.transition_key;

	select	e.employee_id, im_name_from_user_id(e.employee_id), 
		    e.supervisor_id, im_name_from_user_id(e.supervisor_id)
	into	v_owner_id, v_owner_name, 
		    v_supervisor_id, v_supervisor_name
	from	im_employees e
	where	e.employee_id = v_creation_user;

	if v_supervisor_id is not null then

        perform im_workflow__assign_to_vacation_replacement_if(
            p_task_id,
            v_case_id,
            v_supervisor_id,
            v_transition_key,
            v_creation_user,
            v_creation_ip,
            v_object_type
        );

		v_journal_id := journal_entry__new(
		    null, 
            v_case_id,
		    v_transition_key || '' assign_to_supervisor '' || v_supervisor_name,
		    v_transition_key || '' assign_to_supervisor '' || v_supervisor_name,
		    now(), 
            v_creation_user, 
            v_creation_ip,
		    ''Assigning to '' || v_supervisor_name || '', the supervisor of '' || v_owner_name || ''.''
		);

		perform workflow_case__add_task_assignment(p_task_id, v_supervisor_id, ''f'');

		perform workflow_case__notify_assignee (p_task_id, v_supervisor_id, null, null, 
			''wf_'' || v_object_type || ''_assignment_notif'');

	end if;

	return 0;
end;' language 'plpgsql';

-- Unassigned callback that assigns the transition to the supervisor of the owner
-- of the underlying absence
--
create or replace function im_workflow__assign_to_absence_supervisor (integer, text)
returns integer as '
declare
	p_task_id		    alias for $1;
	p_custom_arg		alias for $2;

	v_case_id		    integer;
	v_object_id		    integer;
	v_creation_user		integer;
	v_creation_ip		varchar;
	v_journal_id		integer;
	v_object_type		varchar;
	v_owner_id		    integer;
	v_owner_name		varchar;
	v_supervisor_id		integer;
	v_supervisor_name	varchar;
	v_transition_key	varchar;
	v_str			    text;
	row			        record;
begin
	-- Get information about the transition and the "environment"
    select  tr.transition_key, t.case_id, c.object_id, ua.owner_id, o.creation_ip, o.object_type
    into    v_transition_key, v_case_id, v_object_id, v_owner_id, v_creation_ip, v_object_type
    from    wf_tasks t, wf_cases c, wf_transitions tr, im_user_absences ua, acs_objects o
    where   t.task_id = p_task_id
            and t.case_id = c.case_id
            and o.object_id = c.object_id
            and ua.absence_id = o.object_id
            and t.workflow_key = tr.workflow_key
            and t.transition_key = tr.transition_key;

	select	im_name_from_user_id(e.employee_id), 
            e.supervisor_id, 
            im_name_from_user_id(e.supervisor_id)
	into    v_owner_name, 
            v_supervisor_id,
            v_supervisor_name
	from	im_employees e
	where	e.employee_id = v_owner_id;

	if v_supervisor_id is not null then

        perform im_workflow__assign_to_vacation_replacement_if(
            p_task_id,
            v_case_id,
            v_supervisor_id,
            v_transition_key,
            v_creation_user,
            v_creation_ip,
            v_object_type
        );

		v_journal_id := journal_entry__new(
		    null, 
            v_case_id,
		    v_transition_key || '' assign_to_supervisor '' || v_supervisor_name,
		    v_transition_key || '' assign_to_supervisor '' || v_supervisor_name,
		    now(), 
            v_creation_user, 
            v_creation_ip,
		    ''Assigning to '' || v_supervisor_name || '', the supervisor of '' || v_owner_name || ''.''
		);

		perform workflow_case__add_task_assignment(p_task_id, v_supervisor_id, ''f'');

		perform workflow_case__notify_assignee (p_task_id, v_supervisor_id, null, null, 
			''wf_'' || v_object_type || ''_assignment_notif'');

	end if;

	return 0;

end;' language 'plpgsql';
