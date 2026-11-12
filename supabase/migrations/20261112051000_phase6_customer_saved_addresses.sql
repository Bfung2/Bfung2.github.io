-- Phase 6: owner-scoped saved address book for verified customers.
-- Public schema table is not client-readable or writable; access is through a scoped RPC.
CREATE TABLE IF NOT EXISTS public.customer_saved_addresses (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
 user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
 label text NOT NULL,
 street text NOT NULL,
 city text NOT NULL,
 state text NOT NULL,
 zip text NOT NULL,
 is_default boolean NOT NULL DEFAULT false,
 created_at timestamptz NOT NULL DEFAULT now(),
 updated_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS customer_saved_addresses_user_idx ON public.customer_saved_addresses(user_id,created_at);
CREATE UNIQUE INDEX IF NOT EXISTS customer_saved_addresses_one_default_idx ON public.customer_saved_addresses(user_id) WHERE is_default;
ALTER TABLE public.customer_saved_addresses ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.customer_saved_addresses FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.apex_customer_addresses(
 p_action text DEFAULT 'list',
 p_id uuid DEFAULT NULL,
 p_label text DEFAULT NULL,
 p_address jsonb DEFAULT NULL,
 p_default boolean DEFAULT false
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $func$
DECLARE
 v_user uuid := auth.uid();
 v_label text;
 v_street text;
 v_city text;
 v_state text;
 v_zip text;
 v_id uuid;
 v_result jsonb;
BEGIN
 -- This verifies that the caller owns a confirmed Supabase Auth identity.
 PERFORM public.apex_customer_identity();
 IF v_user IS NULL THEN RAISE EXCEPTION 'Verified customer session required' USING errcode='42501'; END IF;

 IF p_action = 'save' THEN
   IF p_address IS NULL OR jsonb_typeof(p_address) <> 'object' THEN
     RAISE EXCEPTION 'Invalid shipping address';
   END IF;
   v_label := btrim(coalesce(p_label,''));
   v_street := btrim(coalesce(p_address->>'street',''));
   v_city := btrim(coalesce(p_address->>'city',''));
   v_state := btrim(coalesce(p_address->>'state',''));
   v_zip := btrim(coalesce(p_address->>'zip',''));
   IF length(v_label) < 1 OR length(v_label) > 50 OR
      length(v_street) < 5 OR length(v_street) > 200 OR
      length(v_city) < 2 OR length(v_city) > 100 OR
      length(v_state) < 2 OR length(v_state) > 100 OR
      length(v_zip) < 2 OR length(v_zip) > 20 THEN
      RAISE EXCEPTION 'Address details are missing or too long';
   END IF;
   -- Serialize writes within an account to enforce the maximum-address limit.
   PERFORM pg_advisory_xact_lock(hashtext(v_user::text));
   IF p_id IS NULL THEN
     IF (SELECT count(*) FROM public.customer_saved_addresses WHERE user_id = v_user) >= 5 THEN
       RAISE EXCEPTION 'You may save up to five addresses';
     END IF;
     INSERT INTO public.customer_saved_addresses(user_id,label,street,city,state,zip)
     VALUES(v_user,v_label,v_street,v_city,v_state,v_zip) RETURNING id INTO v_id;
   ELSE
     UPDATE public.customer_saved_addresses SET
       label=v_label,street=v_street,city=v_city,state=v_state,zip=v_zip,updated_at=now()
     WHERE id=p_id AND user_id=v_user RETURNING id INTO v_id;
     IF NOT FOUND THEN RAISE EXCEPTION 'Saved address not found' USING errcode='42501'; END IF;
   END IF;
   IF coalesce(p_default,false) OR
     NOT EXISTS(SELECT 1 FROM public.customer_saved_addresses WHERE user_id=v_user AND is_default) THEN
     UPDATE public.customer_saved_addresses SET is_default=false,updated_at=now()
       WHERE user_id=v_user AND is_default AND id<>v_id;
     UPDATE public.customer_saved_addresses SET is_default=true,updated_at=now()
       WHERE user_id=v_user AND id=v_id;
   END IF;
 ELSIF p_action = 'remove' THEN
   DELETE FROM public.customer_saved_addresses WHERE user_id=v_user AND id=p_id;
   IF NOT FOUND THEN RAISE EXCEPTION 'Saved address not found' USING errcode='42501'; END IF;
   IF NOT EXISTS(SELECT 1 FROM public.customer_saved_addresses WHERE user_id=v_user AND is_default) THEN
     UPDATE public.customer_saved_addresses SET is_default=true,updated_at=now()
     WHERE id = (SELECT id FROM public.customer_saved_addresses
                 WHERE user_id=v_user ORDER BY created_at,id LIMIT 1);
   END IF;
 ELSIF p_action = 'set_default' THEN
   IF NOT EXISTS(SELECT 1 FROM public.customer_saved_addresses WHERE user_id=v_user AND id=p_id) THEN
     RAISE EXCEPTION 'Saved address not found' USING errcode='42501';
   END IF;
   UPDATE public.customer_saved_addresses SET is_default=false,updated_at=now()
     WHERE user_id=v_user AND is_default AND id<>p_id;
   UPDATE public.customer_saved_addresses SET is_default=true,updated_at=now()
     WHERE user_id=v_user AND id=p_id;
 ELSIF p_action <> 'list' THEN
   RAISE EXCEPTION 'Unsupported address action';
 END IF;

 SELECT coalesce(jsonb_agg(
   jsonb_build_object('id',id,'label',label,'street',street,'city',city,
     'state',state,'zip',zip,'is_default',is_default)
   ORDER BY is_default DESC,created_at,id
 ),'[]'::jsonb) INTO v_result
 FROM public.customer_saved_addresses WHERE user_id=v_user;
 RETURN v_result;
END
$func$;

REVOKE ALL ON FUNCTION public.apex_customer_addresses(text,uuid,text,jsonb,boolean) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.apex_customer_addresses(text,uuid,text,jsonb,boolean) TO authenticated;
