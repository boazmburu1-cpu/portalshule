-- =====================================================================
-- SCHOOL PORTAL BACKEND  (Supabase / PostgreSQL 15)
-- Run this whole file ONCE in: Supabase Dashboard > SQL Editor.
-- Design rules:
--   * Every table has Row Level Security (RLS). The browser can only do
--     what a policy or an RPC function below allows.
--   * Money is never edited. Balance = invoices - payments (append only).
--   * Business rules (limits, scope, 3-year arrears) live in the database,
--     so nobody can bypass them by calling the API directly.
-- =====================================================================

-- ---------- 1. TYPES -------------------------------------------------
create type user_role     as enum ('parent','subject_teacher','class_teacher','deputy','head','admin');
create type account_status as enum ('pending','active','rejected','suspended');
create type student_status as enum ('pending','accepted','rejected','transferred','graduated');
create type pay_method    as enum ('mpesa','cheque','cash','adjustment');

-- ---------- 2. TABLES ------------------------------------------------
create table school_settings (
  id               int primary key default 1 check (id = 1),
  current_year     int not null default extract(year from now())::int,
  year_end         date not null default make_date(extract(year from now())::int, 11, 30),
  base_fee         numeric(12,2) not null default 45000,
  adj_max          numeric(12,2) not null default 2000,   -- class teacher: max per adjustment
  adj_total_max    numeric(12,2) not null default 5000,   -- class teacher: max per student
  max_arrears_years int not null default 3
);
insert into school_settings default values;

create table profiles (
  id         uuid primary key references auth.users(id) on delete cascade,
  full_name  text not null default '',
  email      text not null unique,
  phone      text,
  role       user_role not null default 'parent',
  status     account_status not null default 'pending',
  created_at timestamptz not null default now()
);
-- one parent = one account (phone must be unique among parents)
create unique index profiles_parent_phone on profiles(phone) where role = 'parent';

create table classes (
  id            uuid primary key default gen_random_uuid(),
  name          text not null unique check (length(trim(name)) between 2 and 20),
  next_class_id uuid references classes(id) on delete set null,
  graduates     boolean not null default false,      -- true = leaves school at year-end
  check (not (graduates and next_class_id is not null)),
  check (next_class_id is distinct from id)
);

create table subjects (
  id   uuid primary key default gen_random_uuid(),
  name text not null unique
);

-- one class teacher <-> one class
create table class_teachers (
  class_id   uuid primary key references classes(id) on delete restrict,
  teacher_id uuid not null unique references profiles(id) on delete cascade
);

-- a subject teacher can teach many subjects in many classes
create table teaching_assignments (
  teacher_id uuid not null references profiles(id) on delete cascade,
  subject_id uuid not null references subjects(id) on delete cascade,
  class_id   uuid not null references classes(id) on delete cascade,
  primary key (teacher_id, subject_id, class_id)
);

create table students (
  id              uuid primary key default gen_random_uuid(),
  full_name       text not null check (length(trim(full_name)) >= 2),
  class_id        uuid not null references classes(id) on delete restrict,   -- blocks class removal while students exist
  parent_id       uuid not null references profiles(id) on delete restrict,
  status          student_status not null default 'pending',
  remark          text,
  transfer_date   date,
  transfer_to     text,
  transfer_reason text,
  transferred_by  uuid references profiles(id),
  created_at      timestamptz not null default now()
);
create index on students(parent_id);
create index on students(class_id);

create table attendance_sessions (
  id            uuid primary key default gen_random_uuid(),
  class_id      uuid not null references classes(id) on delete cascade,
  academic_year int not null,
  session_date  date not null,
  taken_by      uuid references profiles(id),
  unique (class_id, session_date)
);
create table attendance_records (
  session_id uuid not null references attendance_sessions(id) on delete cascade,
  student_id uuid not null references students(id) on delete cascade,
  present    boolean not null,
  primary key (session_id, student_id)
);

create table marks (
  id            uuid primary key default gen_random_uuid(),
  student_id    uuid not null references students(id) on delete cascade,
  subject_id    uuid not null references subjects(id) on delete restrict,
  academic_year int not null,
  score         numeric(5,2) not null check (score between 0 and 100),
  review        text,
  entered_by    uuid references profiles(id),
  corrected_by  uuid references profiles(id),
  updated_at    timestamptz not null default now(),
  unique (student_id, subject_id, academic_year)
);
create index on marks(student_id);

-- one invoice per student per year; unpaid years simply stay unpaid (the arrears sum)
create table fee_invoices (
  id            uuid primary key default gen_random_uuid(),
  student_id    uuid not null references students(id) on delete restrict,
  academic_year int not null,
  amount_due    numeric(12,2) not null check (amount_due >= 0),
  created_at    timestamptz not null default now(),
  unique (student_id, academic_year)
);

-- append-only ledger
create table payments (
  id          uuid primary key default gen_random_uuid(),
  student_id  uuid not null references students(id) on delete restrict,
  amount      numeric(12,2) not null check (amount > 0),
  method      pay_method not null,
  reference   text,               -- M-Pesa receipt, cheque no., cash receipt no., or adjustment reason
  note        text,
  recorded_by uuid references profiles(id),   -- null = system (M-Pesa callback)
  created_at  timestamptz not null default now()
);
create index on payments(student_id);
create unique index payments_mpesa_ref on payments(reference) where method = 'mpesa';  -- Safaricom may call twice

create table mpesa_requests (
  id                  uuid primary key default gen_random_uuid(),
  student_id          uuid not null references students(id),
  parent_id           uuid not null references profiles(id),
  phone               text not null,
  amount              numeric(12,2) not null check (amount > 0),
  checkout_request_id text unique,
  merchant_request_id text,
  status              text not null default 'pending' check (status in ('pending','success','failed')),
  mpesa_receipt       text,
  result_desc         text,
  created_at          timestamptz not null default now()
);

create table notifications (
  id         uuid primary key default gen_random_uuid(),
  user_id    uuid not null references profiles(id) on delete cascade,
  body       text not null,
  read       boolean not null default false,
  created_at timestamptz not null default now()
);
create index on notifications(user_id, read);

-- head bypass: valid for ONE year-end only (keyed by academic year)
create table promotion_bypasses (
  student_id    uuid not null references students(id) on delete cascade,
  academic_year int not null,
  approved_by   uuid references profiles(id),
  approved_at   timestamptz not null default now(),
  primary key (student_id, academic_year)
);

create table academic_history (
  id                 uuid primary key default gen_random_uuid(),
  student_id         uuid not null references students(id) on delete cascade,
  academic_year      int not null,
  class_name         text,
  average            numeric(5,2),
  balance            numeric(12,2),
  outcome            text,
  marks              jsonb not null default '[]',
  attendance_present int not null default 0,
  attendance_total   int not null default 0,
  remark             text,
  created_at         timestamptz not null default now()
);

create table audit_log (
  id         bigint generated always as identity primary key,
  actor      uuid,
  action     text not null,
  detail     jsonb,
  created_at timestamptz not null default now()
);

-- ---------- 3. HELPER FUNCTIONS -------------------------------------
create function auth_role() returns user_role
language sql stable security definer set search_path = public as $$
  select role from profiles where id = auth.uid() and status = 'active'
$$;

create function has_role(variadic r user_role[]) returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce(auth_role() = any(r), false)
$$;

create function student_class(sid uuid) returns uuid
language sql stable security definer set search_path = public as $$
  select class_id from students where id = sid
$$;

create function owns_student(sid uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce(exists(select 1 from students where id = sid and parent_id = auth.uid()) and has_role('parent'), false)
$$;

create function my_class() returns uuid
language sql stable security definer set search_path = public as $$
  select class_id from class_teachers where teacher_id = auth.uid() and has_role('class_teacher')
$$;

create function teaches(cid uuid, subid uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce(exists(select 1 from teaching_assignments
                         where teacher_id = auth.uid() and class_id = cid and subject_id = subid)
                  and has_role('subject_teacher'), false)
$$;

create function teaches_class(cid uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce(exists(select 1 from teaching_assignments where teacher_id = auth.uid() and class_id = cid)
                  and has_role('subject_teacher'), false)
$$;

-- balance = everything invoiced - everything paid
create function student_balance(sid uuid) returns numeric
language sql stable as $$
  select coalesce((select sum(amount_due) from fee_invoices where student_id = sid), 0)
       - coalesce((select sum(amount)     from payments     where student_id = sid), 0)
$$;

-- what is still unpaid, per year. Payments clear the OLDEST year first.
create function student_owing(sid uuid) returns table(academic_year int, unpaid numeric)
language sql stable as $$
  with inv as (
    select i.academic_year, i.amount_due,
           sum(i.amount_due) over (order by i.academic_year) as cum
    from fee_invoices i where i.student_id = sid
  ), paid as (select coalesce(sum(amount), 0) as p from payments where student_id = sid)
  select inv.academic_year, greatest(0, least(inv.amount_due, inv.cum - paid.p))
  from inv, paid
  where greatest(0, least(inv.amount_due, inv.cum - paid.p)) > 0
  order by inv.academic_year
$$;

create function notify_user(uid uuid, msg text) returns void
language sql security definer set search_path = public as $$
  insert into notifications(user_id, body) values (uid, msg)
$$;

create function audit_add(act text, det jsonb) returns void
language sql security definer set search_path = public as $$
  insert into audit_log(actor, action, detail) values (auth.uid(), act, det)
$$;

-- ---------- 4. TRIGGERS ---------------------------------------------
-- New sign-ups are ALWAYS pending parents. Role/status can never come from the client.
create function handle_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into profiles(id, full_name, email, phone)
  values (new.id, coalesce(new.raw_user_meta_data->>'full_name', ''), lower(new.email),
          nullif(trim(new.raw_user_meta_data->>'phone'), ''));
  return new;
end $$;
create trigger on_auth_user_created after insert on auth.users
  for each row execute function handle_new_user();

create function sync_email() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  update profiles set email = lower(new.email) where id = new.id;
  return new;
end $$;
create trigger on_auth_email_changed after update of email on auth.users
  for each row execute function sync_email();

-- payments can never be edited or deleted, and never exceed the balance
create function payments_guard() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if tg_op in ('UPDATE','DELETE') then
    raise exception 'Payments are permanent and cannot be changed';
  end if;
  if new.amount > student_balance(new.student_id) then
    raise exception 'Payment exceeds the outstanding balance';
  end if;
  return new;
end $$;
create trigger payments_guard_trg before insert or update or delete on payments
  for each row execute function payments_guard();

-- ---------- 5. ROW LEVEL SECURITY -----------------------------------
alter table school_settings      enable row level security;
alter table profiles             enable row level security;
alter table classes              enable row level security;
alter table subjects             enable row level security;
alter table class_teachers       enable row level security;
alter table teaching_assignments enable row level security;
alter table students             enable row level security;
alter table attendance_sessions  enable row level security;
alter table attendance_records   enable row level security;
alter table marks                enable row level security;
alter table fee_invoices         enable row level security;
alter table payments             enable row level security;
alter table mpesa_requests       enable row level security;
alter table notifications        enable row level security;
alter table promotion_bypasses   enable row level security;
alter table academic_history     enable row level security;
alter table audit_log            enable row level security;

-- settings, classes, subjects: any ACTIVE user reads; admin changes
create policy settings_read on school_settings for select to authenticated using (auth_role() is not null);
create policy settings_admin on school_settings for update to authenticated using (has_role('admin')) with check (has_role('admin'));
create policy classes_read on classes for select to authenticated using (auth_role() is not null);
create policy classes_admin on classes for all to authenticated using (has_role('admin')) with check (has_role('admin'));
create policy subjects_read on subjects for select to authenticated using (auth_role() is not null);
create policy subjects_admin on subjects for all to authenticated using (has_role('admin')) with check (has_role('admin'));

-- profiles: own row; head/admin see everyone; deputy sees parents (to prompt them)
create policy profiles_read on profiles for select to authenticated using (
  id = auth.uid() or has_role('head','admin') or (has_role('deputy') and role = 'parent'));

-- staff assignments: head and admin manage, staff read their own
create policy ct_read on class_teachers for select to authenticated using (
  teacher_id = auth.uid() or has_role('head','deputy','admin'));
create policy ct_write on class_teachers for all to authenticated using (has_role('head','admin')) with check (has_role('head','admin'));
create policy ta_read on teaching_assignments for select to authenticated using (
  teacher_id = auth.uid() or has_role('head','deputy','admin'));
create policy ta_write on teaching_assignments for all to authenticated using (has_role('head','admin')) with check (has_role('head','admin'));

-- students: parent sees own children; class teacher their class; subject teacher classes they teach
create policy students_read on students for select to authenticated using (
  (parent_id = auth.uid() and has_role('parent'))
  or class_id = my_class()
  or teaches_class(class_id)
  or has_role('deputy','head','admin'));
create policy students_parent_add on students for insert to authenticated with check (
  parent_id = auth.uid() and status = 'pending' and has_role('parent'));

create policy marks_read on marks for select to authenticated using (
  has_role('admin') or owns_student(student_id)
  or student_class(student_id) = my_class()
  or teaches(student_class(student_id), subject_id));

create policy att_sessions_read on attendance_sessions for select to authenticated using (
  class_id = my_class() or has_role('admin'));
create policy att_records_read on attendance_records for select to authenticated using (
  owns_student(student_id) or has_role('admin')
  or exists(select 1 from attendance_sessions a where a.id = session_id and a.class_id = my_class()));

create policy invoices_read on fee_invoices for select to authenticated using (
  has_role('deputy','head','admin') or owns_student(student_id) or student_class(student_id) = my_class());
create policy payments_read on payments for select to authenticated using (
  has_role('deputy','head','admin') or owns_student(student_id) or student_class(student_id) = my_class());

create policy mpesa_read on mpesa_requests for select to authenticated using (
  parent_id = auth.uid() or has_role('head','admin'));

create policy notif_read on notifications for select to authenticated using (user_id = auth.uid());
create policy notif_update on notifications for update to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid());

create policy bypass_read on promotion_bypasses for select to authenticated using (has_role('head','deputy','admin'));
create policy history_read on academic_history for select to authenticated using (owns_student(student_id) or has_role('admin'));
create policy audit_read on audit_log for select to authenticated using (has_role('admin'));

-- ---------- 6. RPC FUNCTIONS (the only way to change sensitive data) --

-- internal: records a payment, notifies the parent. NOT callable by the browser.
create function post_payment(p_student uuid, p_amount numeric, p_method pay_method,
                             p_ref text, p_note text, p_by uuid) returns uuid
language plpgsql security definer set search_path = public as $$
declare pid uuid; pr uuid; sname text;
begin
  insert into payments(student_id, amount, method, reference, note, recorded_by)
  values (p_student, p_amount, p_method, p_ref, p_note, p_by) returning id into pid;
  select parent_id, full_name into pr, sname from students where id = p_student;
  perform notify_user(pr, format('Fees update for %s: KES %s received (%s%s). New balance: KES %s.',
      sname, to_char(p_amount, 'FM999,999,990.00'), p_method,
      case when coalesce(p_ref,'') <> '' and p_method <> 'adjustment' then ', ' || p_ref else '' end,
      to_char(student_balance(p_student), 'FM999,999,990.00')));
  perform audit_add('payment', jsonb_build_object('student', p_student, 'amount', p_amount, 'method', p_method, 'ref', p_ref));
  return pid;
end $$;

-- internal: snapshot of a student's year for the permanent record
create function archive_student(p_student uuid, p_outcome text) returns void
language plpgsql security definer set search_path = public as $$
declare s students; yr int; cname text;
begin
  select * into s from students where id = p_student;
  select current_year into yr from school_settings where id = 1;
  select name into cname from classes where id = s.class_id;
  insert into academic_history(student_id, academic_year, class_name, average, balance, outcome,
                               marks, attendance_present, attendance_total, remark)
  select p_student, yr, cname,
    (select round(avg(score), 2) from marks where student_id = p_student and academic_year = yr),
    greatest(student_balance(p_student), 0), p_outcome,
    coalesce((select jsonb_agg(jsonb_build_object('subject', sb.name, 'score', m.score, 'review', m.review) order by sb.name)
              from marks m join subjects sb on sb.id = m.subject_id
              where m.student_id = p_student and m.academic_year = yr), '[]'::jsonb),
    (select count(*) from attendance_records r join attendance_sessions a on a.id = r.session_id
       where r.student_id = p_student and a.academic_year = yr and r.present),
    (select count(*) from attendance_records r join attendance_sessions a on a.id = r.session_id
       where r.student_id = p_student and a.academic_year = yr),
    s.remark;
end $$;

-- HEAD: approve / reject a registered parent
create function approve_parent(p_id uuid, p_approve boolean) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not has_role('head') then raise exception 'Only the head teacher can approve parents'; end if;
  update profiles set status = (case when p_approve then 'active' else 'rejected' end)::account_status
   where id = p_id and role = 'parent' and status = 'pending';
  if not found then raise exception 'No pending parent found'; end if;
  perform audit_add(case when p_approve then 'parent_approved' else 'parent_rejected' end, jsonb_build_object('parent', p_id));
end $$;

-- HEAD: rename a student.  (Parent email changes need the auth admin API: see Edge Function notes.)
create function head_rename_student(p_student uuid, p_name text) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not has_role('head') then raise exception 'Only the head teacher can do this'; end if;
  if length(trim(coalesce(p_name,''))) < 2 then raise exception 'Name is too short'; end if;
  update students set full_name = trim(p_name) where id = p_student;
  perform audit_add('student_renamed', jsonb_build_object('student', p_student, 'name', trim(p_name)));
end $$;

-- HEAD / ADMIN: remove (suspend) staff. Head -> teachers. Admin -> anyone but themselves.
create function remove_staff(p_id uuid) returns void
language plpgsql security definer set search_path = public as $$
declare r user_role;
begin
  select role into r from profiles where id = p_id;
  if r is null or r = 'parent' then raise exception 'Not a staff account'; end if;
  if p_id = auth.uid() then raise exception 'You cannot remove yourself'; end if;
  if not (has_role('admin') or (has_role('head') and r in ('subject_teacher','class_teacher'))) then
    raise exception 'You are not allowed to remove this account';
  end if;
  update profiles set status = 'suspended' where id = p_id;
  delete from class_teachers where teacher_id = p_id;
  delete from teaching_assignments where teacher_id = p_id;
  perform audit_add('staff_removed', jsonb_build_object('staff', p_id, 'role', r));
end $$;

-- HEAD / ADMIN: year-end date
create function set_year_end(p_date date) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not has_role('head','admin') then raise exception 'Not allowed'; end if;
  if p_date < current_date then raise exception 'The year-end date cannot be in the past'; end if;
  update school_settings set year_end = p_date where id = 1;
  perform audit_add('year_end_set', jsonb_build_object('date', p_date));
end $$;

-- CLASS TEACHER: accept / reject a student of their own class
create function class_decide_student(p_student uuid, p_accept boolean) returns void
language plpgsql security definer set search_path = public as $$
declare s students; yr int; fee numeric;
begin
  if my_class() is null or student_class(p_student) is distinct from my_class() then
    raise exception 'This student is not in your class';
  end if;
  select * into s from students where id = p_student;
  if s.status <> 'pending' then raise exception 'Student is not pending'; end if;
  update students set status = (case when p_accept then 'accepted' else 'rejected' end)::student_status where id = p_student;
  if p_accept then
    select current_year, base_fee into yr, fee from school_settings where id = 1;
    insert into fee_invoices(student_id, academic_year, amount_due) values (p_student, yr, fee)
      on conflict (student_id, academic_year) do nothing;
  end if;
  perform notify_user(s.parent_id, format('%s was %s by the class teacher.', s.full_name,
          case when p_accept then 'accepted into class' else 'not accepted' end));
  perform audit_add('student_decision', jsonb_build_object('student', p_student, 'accepted', p_accept));
end $$;

-- CLASS TEACHER: sign attendance for today (or a past date) for the whole class
create function save_attendance(p_date date, p_present uuid[]) returns void
language plpgsql security definer set search_path = public as $$
declare cid uuid := my_class(); sid uuid; yr int;
begin
  if cid is null then raise exception 'Only a class teacher can sign attendance'; end if;
  if p_date > current_date then raise exception 'You cannot sign attendance for a future date'; end if;
  select current_year into yr from school_settings where id = 1;
  insert into attendance_sessions(class_id, academic_year, session_date, taken_by)
    values (cid, yr, p_date, auth.uid())
    on conflict (class_id, session_date) do update set taken_by = auth.uid()
    returning id into sid;
  delete from attendance_records where session_id = sid;
  insert into attendance_records(session_id, student_id, present)
    select sid, s.id, s.id = any(coalesce(p_present, '{}'::uuid[]))
    from students s where s.class_id = cid and s.status = 'accepted';
end $$;

-- CLASS TEACHER: correct an EXISTING mark (only subject teachers create marks)
create function class_correct_mark(p_mark uuid, p_score numeric) returns void
language plpgsql security definer set search_path = public as $$
declare m marks;
begin
  select * into m from marks where id = p_mark;
  if not found or my_class() is null or student_class(m.student_id) is distinct from my_class() then
    raise exception 'This mark is not in your class';
  end if;
  if p_score is null or p_score < 0 or p_score > 100 then raise exception 'Score must be 0-100'; end if;
  update marks set score = p_score, corrected_by = auth.uid(), updated_at = now() where id = p_mark;
  perform audit_add('mark_corrected', jsonb_build_object('mark', p_mark, 'old', m.score, 'new', p_score));
end $$;

-- CLASS TEACHER: report-form remark
create function class_set_remark(p_student uuid, p_remark text) returns void
language plpgsql security definer set search_path = public as $$
begin
  if my_class() is null or student_class(p_student) is distinct from my_class() then
    raise exception 'This student is not in your class';
  end if;
  update students set remark = nullif(trim(p_remark), '') where id = p_student;
end $$;

-- CLASS TEACHER: limited balance update (max per entry, max per student, reason, never below zero)
create function class_adjust_balance(p_student uuid, p_amount numeric, p_reason text) returns void
language plpgsql security definer set search_path = public as $$
declare cfg school_settings; used numeric; s students;
begin
  if my_class() is null or student_class(p_student) is distinct from my_class() then
    raise exception 'This student is not in your class';
  end if;
  select * into cfg from school_settings where id = 1;
  select * into s from students where id = p_student;
  if s.status <> 'accepted' then raise exception 'Student is not enrolled'; end if;
  if p_amount is null or p_amount < 1 or p_amount > cfg.adj_max then
    raise exception 'One adjustment is limited to KES %', cfg.adj_max;
  end if;
  if p_amount > student_balance(p_student) then raise exception 'Adjustment cannot exceed the balance'; end if;
  select coalesce(sum(amount), 0) into used from payments where student_id = p_student and method = 'adjustment';
  if used + p_amount > cfg.adj_total_max then
    raise exception 'Total adjustments per student are limited to KES % (used %)', cfg.adj_total_max, used;
  end if;
  if length(trim(coalesce(p_reason, ''))) < 5 then raise exception 'Give a reason (5+ characters)'; end if;
  perform post_payment(p_student, p_amount, 'adjustment', trim(p_reason), null, auth.uid());
end $$;

-- SUBJECT TEACHER: add / update a mark with a review (only for own subject + class)
create function save_mark(p_student uuid, p_subject uuid, p_score numeric, p_review text default null) returns void
language plpgsql security definer set search_path = public as $$
declare s students; yr int; subname text;
begin
  select * into s from students where id = p_student;
  if not found or s.status <> 'accepted' then raise exception 'Student is not enrolled'; end if;
  if not teaches(s.class_id, p_subject) then raise exception 'You do not teach this subject in this class'; end if;
  if p_score is null or p_score < 0 or p_score > 100 then raise exception 'Score must be 0-100'; end if;
  select current_year into yr from school_settings where id = 1;
  select name into subname from subjects where id = p_subject;
  insert into marks(student_id, subject_id, academic_year, score, review, entered_by)
    values (p_student, p_subject, yr, p_score, nullif(trim(p_review), ''), auth.uid())
    on conflict (student_id, subject_id, academic_year)
    do update set score = excluded.score, review = excluded.review, entered_by = auth.uid(), updated_at = now();
  perform notify_user(s.parent_id, format('New %s result for %s: %s.', subname, s.full_name, p_score));
end $$;

create function set_mark_review(p_mark uuid, p_review text) returns void
language plpgsql security definer set search_path = public as $$
declare m marks;
begin
  select * into m from marks where id = p_mark;
  if not found or not teaches(student_class(m.student_id), m.subject_id) then
    raise exception 'You do not teach this subject in this class';
  end if;
  update marks set review = nullif(trim(p_review), ''), updated_at = now() where id = p_mark;
end $$;

-- DEPUTY: record a cheque or cash payment (cash needs explicit confirmation, not recommended)
create function record_payment(p_student uuid, p_amount numeric, p_method pay_method,
                               p_reference text, p_confirm_cash boolean default false) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not has_role('deputy') then raise exception 'Only the deputy head can record payments'; end if;
  if p_method not in ('cheque','cash') then raise exception 'Use cheque or cash here (M-Pesa is automatic)'; end if;
  if p_method = 'cash' and not coalesce(p_confirm_cash, false) then
    raise exception 'Cash is not recommended. Confirm the cash payment to continue';
  end if;
  if length(trim(coalesce(p_reference, ''))) < 3 then raise exception 'Enter the cheque or receipt number'; end if;
  if (select status from students where id = p_student) <> 'accepted'
     and (select status from students where id = p_student) <> 'transferred' then
    raise exception 'Student is not enrolled';
  end if;
  perform post_payment(p_student, p_amount, p_method, trim(p_reference), null, auth.uid());
end $$;

-- DEPUTY: prompt (remind) a parent about an unpaid balance
create function prompt_parent(p_student uuid) returns void
language plpgsql security definer set search_path = public as $$
declare s students; b numeric;
begin
  if not has_role('deputy') then raise exception 'Only the deputy head can prompt parents'; end if;
  select * into s from students where id = p_student;
  b := student_balance(p_student);
  if b <= 0 then raise exception 'No balance is owed'; end if;
  perform notify_user(s.parent_id, format('Reminder from the deputy head: %s has a fee balance of KES %s. Please pay by M-Pesa or at the school office.',
          s.full_name, to_char(b, 'FM999,999,990.00')));
  perform audit_add('parent_prompted', jsonb_build_object('student', p_student, 'balance', b));
end $$;

-- DEPUTY / HEAD / ADMIN: class averages per subject and in total (never individual students)
create function class_averages() returns table(class_name text, subject_name text, average numeric)
language plpgsql stable security definer set search_path = public as $$
declare yr int;
begin
  if not has_role('deputy','head','admin') then raise exception 'Not allowed'; end if;
  select current_year into yr from school_settings where id = 1;
  return query
    select c.name, sb.name, round(avg(m.score), 1)
      from marks m
      join students s on s.id = m.student_id and s.status = 'accepted'
      join classes c on c.id = s.class_id
      join subjects sb on sb.id = m.subject_id
     where m.academic_year = yr
     group by c.name, sb.name
    union all
    select c.name, null::text, round(avg(sa.a), 1)
      from (select s.class_id, avg(m.score) as a
              from marks m join students s on s.id = m.student_id and s.status = 'accepted'
             where m.academic_year = yr group by s.id, s.class_id) sa
      join classes c on c.id = sa.class_id
     group by c.name;
end $$;

-- HEAD: transfer a student out (record archived, balance stays owed)
create function transfer_student(p_student uuid, p_date date, p_to text, p_reason text) returns void
language plpgsql security definer set search_path = public as $$
declare s students;
begin
  if not has_role('head') then raise exception 'Only the head teacher can transfer students'; end if;
  select * into s from students where id = p_student;
  if not found or s.status <> 'accepted' then raise exception 'Student is not enrolled'; end if;
  if length(trim(coalesce(p_reason, ''))) < 3 then raise exception 'A reason is required'; end if;
  perform archive_student(p_student, 'Transferred out');
  update students set status = 'transferred', transfer_date = p_date, transfer_to = nullif(trim(p_to), ''),
         transfer_reason = trim(p_reason), transferred_by = auth.uid() where id = p_student;
  delete from promotion_bypasses where student_id = p_student;
  perform notify_user(s.parent_id, format('%s has been transferred out of the school%s. %s', s.full_name,
          case when coalesce(trim(p_to), '') <> '' then ' to ' || trim(p_to) else '' end,
          case when student_balance(p_student) > 0
               then 'Outstanding fee balance: KES ' || to_char(student_balance(p_student), 'FM999,999,990.00') || '.'
               else 'No fees are outstanding.' end));
  perform audit_add('student_transferred', jsonb_build_object('student', p_student, 'to', p_to, 'reason', p_reason));
end $$;

-- HEAD: the ONE place a head sees an individual's full record (to decide a bypass)
create function head_review_student(p_student uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare s students; yr int;
begin
  if not has_role('head') then raise exception 'Only the head teacher can do this'; end if;
  select * into s from students where id = p_student and status = 'accepted';
  if not found then raise exception 'Student not found'; end if;
  if student_balance(p_student) <= 0 then
    raise exception 'Individual records are shown only when a fee bypass is being considered';
  end if;
  select current_year into yr from school_settings where id = 1;
  return jsonb_build_object(
    'student', s.full_name,
    'class', (select name from classes where id = s.class_id),
    'balance', student_balance(p_student),
    'owing', (select coalesce(jsonb_agg(jsonb_build_object('year', academic_year, 'unpaid', unpaid)), '[]'::jsonb) from student_owing(p_student)),
    'current_marks', (select coalesce(jsonb_agg(jsonb_build_object('subject', sb.name, 'score', m.score, 'review', m.review) order by sb.name), '[]'::jsonb)
                       from marks m join subjects sb on sb.id = m.subject_id where m.student_id = p_student and m.academic_year = yr),
    'attendance_present', (select count(*) from attendance_records r join attendance_sessions a on a.id = r.session_id
                            where r.student_id = p_student and a.academic_year = yr and r.present),
    'attendance_total', (select count(*) from attendance_records r join attendance_sessions a on a.id = r.session_id
                          where r.student_id = p_student and a.academic_year = yr),
    'remark', s.remark,
    'history', (select coalesce(jsonb_agg(to_jsonb(h) - 'id' - 'student_id' order by h.academic_year), '[]'::jsonb)
                  from academic_history h where h.student_id = p_student));
end $$;

-- HEAD: approve / remove a bypass. Valid for the CURRENT year-end only. Not allowed at the arrears limit.
create function approve_bypass(p_student uuid) returns void
language plpgsql security definer set search_path = public as $$
declare cfg school_settings; yrs int;
begin
  if not has_role('head') then raise exception 'Only the head teacher can approve a bypass'; end if;
  select * into cfg from school_settings where id = 1;
  if (select status from students where id = p_student) is distinct from 'accepted' then raise exception 'Student is not enrolled'; end if;
  if student_balance(p_student) <= 0 then raise exception 'No fees are outstanding, so no bypass is needed'; end if;
  select count(*) into yrs from student_owing(p_student);
  if yrs >= cfg.max_arrears_years then
    raise exception '% years of fees are unpaid (limit reached). A bypass is not allowed', yrs;
  end if;
  insert into promotion_bypasses(student_id, academic_year, approved_by)
    values (p_student, cfg.current_year, auth.uid()) on conflict do nothing;
  perform audit_add('bypass_approved', jsonb_build_object('student', p_student, 'year', cfg.current_year));
end $$;

create function remove_bypass(p_student uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not has_role('head') then raise exception 'Only the head teacher can do this'; end if;
  delete from promotion_bypasses
   where student_id = p_student and academic_year = (select current_year from school_settings where id = 1);
  perform audit_add('bypass_removed', jsonb_build_object('student', p_student));
end $$;

-- YEAR-END PROMOTION.
-- Automatic: scheduled daily (see section 8); does nothing until today is past year_end.
-- Head can force it. Rules per accepted student:
--   next class not set -> held | fees cleared -> promoted | 3 years unpaid -> held, no bypass
--   head bypass for this year -> promoted | otherwise held.
-- Unpaid years simply stay as unpaid invoices (that is the "sum"). A frozen student gets no new invoice.
create function run_year_end(p_force boolean default false) returns jsonb
language plpgsql security definer set search_path = public as $$
declare cfg school_settings; s record; cur classes; v_bal numeric; v_yrs int; v_go boolean; v_byp boolean;
        v_frozen boolean; v_outcome text; up int := 0; hold int := 0; grad int := 0; ny int;
begin
  select * into cfg from school_settings where id = 1;
  if p_force then
    if not has_role('head') then raise exception 'Only the head teacher can run year-end now'; end if;
  else
    if auth.uid() is not null and not has_role('head','admin') then raise exception 'Not allowed'; end if;
    if current_date <= cfg.year_end then return jsonb_build_object('ran', false); end if;
  end if;
  ny := cfg.current_year + 1;
  for s in select * from students where status = 'accepted' for update loop
    select * into cur from classes where id = s.class_id;
    v_bal := student_balance(s.id);
    select count(*) into v_yrs from student_owing(s.id);
    v_byp := exists(select 1 from promotion_bypasses where student_id = s.id and academic_year = cfg.current_year);
    v_frozen := v_yrs >= cfg.max_arrears_years;
    if not cur.graduates and cur.next_class_id is null then v_go := false; v_outcome := 'Held: next class not set';
    elsif v_bal <= 0 then v_go := true; v_outcome := 'Promoted';
    elsif v_frozen then v_go := false; v_outcome := 'Held: arrears limit reached';
    elsif v_byp then v_go := true; v_outcome := 'Promoted (head bypass)';
    else v_go := false; v_outcome := 'Held: fees not cleared'; end if;
    perform archive_student(s.id, v_outcome);
    if v_go and cur.graduates then
      update students set status = 'graduated', remark = null where id = s.id; grad := grad + 1; up := up + 1;
    elsif v_go then
      update students set class_id = cur.next_class_id, remark = null where id = s.id; up := up + 1;
    else
      update students set remark = null where id = s.id; hold := hold + 1;
    end if;
    if not (v_go and cur.graduates) and not v_frozen then
      insert into fee_invoices(student_id, academic_year, amount_due) values (s.id, ny, cfg.base_fee)
        on conflict (student_id, academic_year) do nothing;
    end if;
    perform notify_user(s.parent_id,
      case when v_go then format('%s %s for %s.%s', s.full_name,
             case when cur.graduates then 'has graduated' else 'moves to ' || (select name from classes where id = cur.next_class_id) end, ny,
             case when v_bal > 0 then ' Balance carried forward: KES ' || to_char(v_bal, 'FM999,999,990.00') || '.' else '' end)
           else format('%s was not promoted for %s: %s. Please clear KES %s and speak to the head teacher.', s.full_name, ny,
             replace(v_outcome, 'Held: ', ''), to_char(greatest(v_bal, 0), 'FM999,999,990.00')) end);
  end loop;
  update school_settings set current_year = ny, year_end = (cfg.year_end + interval '1 year')::date where id = 1;
  perform audit_add('year_end_run', jsonb_build_object('year', cfg.current_year, 'promoted', up, 'graduated', grad, 'held', hold));
  return jsonb_build_object('ran', true, 'year', cfg.current_year, 'promoted', up, 'graduated', grad, 'held', hold);
end $$;

-- ---------- 7. VIEW + PRIVILEGES ------------------------------------
create view student_fee_summary with (security_invoker = true) as
  select s.id as student_id, s.full_name, s.class_id, s.parent_id, s.status,
         coalesce((select sum(amount_due) from fee_invoices i where i.student_id = s.id), 0) as total_due,
         coalesce((select sum(amount)     from payments p     where p.student_id = s.id), 0) as total_paid,
         student_balance(s.id) as balance
    from students s;

-- tables: browser may only read (RLS decides what), plus a few direct writes
revoke all on all tables in schema public from anon;
revoke insert, update, delete, truncate on all tables in schema public from authenticated;
grant select on all tables in schema public to authenticated;
grant insert on students to authenticated;                                   -- parent adds a child (pending)
grant insert, update, delete on classes, subjects, class_teachers, teaching_assignments to authenticated;  -- RLS: admin/head only
grant update on school_settings to authenticated;                            -- RLS: admin only
grant update (read) on notifications to authenticated;                       -- mark as read

-- functions: signed-in users may call RPCs; internal ones are server-only
revoke execute on all functions in schema public from public, anon, authenticated;
grant  execute on all functions in schema public to authenticated;
revoke execute on function post_payment(uuid, numeric, pay_method, text, text, uuid) from authenticated;
revoke execute on function notify_user(uuid, text) from authenticated;
revoke execute on function audit_add(text, jsonb) from authenticated;
revoke execute on function archive_student(uuid, text) from authenticated;
revoke execute on function handle_new_user() from authenticated;
revoke execute on function sync_email() from authenticated;
revoke execute on function payments_guard() from authenticated;
grant  execute on function post_payment(uuid, numeric, pay_method, text, text, uuid) to service_role;  -- M-Pesa callback (Edge Function)

-- ---------- 8. STARTER DATA + SETUP STEPS ----------------------------
insert into subjects(name) values ('Maths'), ('English'), ('Science'), ('Kiswahili');
insert into classes(name) values ('Grade 6A'), ('Grade 6B'), ('Grade 7A');
update classes set next_class_id = (select id from classes where name = 'Grade 7A') where name in ('Grade 6A', 'Grade 6B');
update classes set graduates = true where name = 'Grade 7A';

-- FIRST ADMIN (do this once, after running the file):
--   1) Dashboard > Authentication > Users > "Add user" (email + password).
--   2) Then run (replace the email):
--        update profiles set role = 'admin', status = 'active', full_name = 'System Admin'
--         where email = 'you@school.ke';
--
-- AUTOMATIC YEAR-END (run after enabling Database > Extensions > pg_cron):
--   select cron.schedule('year-end-daily', '0 1 * * *', $$ select run_year_end(false) $$);
