-- Glass Rail's New York Penn track checker: a helper for part 2.

-- RailData answers a list where it means one, and null where it means none.
create function public.penn_list(j jsonb) returns jsonb
language sql immutable set search_path = '' as $$
  select case when jsonb_typeof(j) = 'array' then j else '[]'::jsonb end
$$;
