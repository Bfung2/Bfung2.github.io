-- Separate employee contact email from the internal Auth email used for six-digit passcodes.
alter table public.employee_profiles
  add column if not exists email text;
