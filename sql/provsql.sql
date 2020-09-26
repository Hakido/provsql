-- Requires extensions "uuid-ossp"

CREATE SCHEMA provsql;

SET search_path TO provsql;

CREATE DOMAIN provenance_token AS UUID NOT NULL;

CREATE TYPE provenance_gate AS
  ENUM('input','plus','times','monus','project','zero','one','eq');

CREATE OR REPLACE FUNCTION create_gate(
  token provenance_token,
  type provenance_gate,
  children provenance_token[] DEFAULT NULL)
  RETURNS void AS
  'provsql','create_gate' LANGUAGE C;
CREATE OR REPLACE FUNCTION get_gate_type(
  token provenance_token)
  RETURNS provenance_gate AS
  'provsql','get_gate_type' LANGUAGE C;
CREATE OR REPLACE FUNCTION get_children(
  token provenance_token)
  RETURNS provenance_token[] AS
  'provsql','get_children' LANGUAGE C;
CREATE OR REPLACE FUNCTION set_prob(
  token provenance_token, p DOUBLE PRECISION)
  RETURNS void AS
  'provsql','set_prob' LANGUAGE C;
CREATE OR REPLACE FUNCTION get_prob(
  token provenance_token)
  RETURNS DOUBLE PRECISION AS
  'provsql','get_prob' LANGUAGE C;

CREATE UNLOGGED TABLE provenance_circuit_extra(
  gate provenance_token,
  info1 INT,
  info2 INT);

CREATE INDEX ON provenance_circuit_extra (gate);

CREATE OR REPLACE FUNCTION add_gate_trigger()
  RETURNS TRIGGER AS
$$
DECLARE
  attribute RECORD;
BEGIN
  PERFORM create_gate(NEW.provsql, 'input');
  RETURN NEW; 
END
$$ LANGUAGE plpgsql SET search_path=provsql,pg_temp SECURITY DEFINER;

CREATE OR REPLACE FUNCTION add_provenance(_tbl regclass)
  RETURNS void AS
$$
BEGIN
  EXECUTE format('ALTER TABLE %I ADD COLUMN provsql provsql.provenance_token UNIQUE DEFAULT uuid_generate_v4()', _tbl);
  EXECUTE format('SELECT create_gate(provsql, ''input'') FROM %I', _tbl);
  EXECUTE format('CREATE TRIGGER add_gate BEFORE INSERT ON %I FOR EACH ROW EXECUTE PROCEDURE provsql.add_gate_trigger()',_tbl);
END
$$ LANGUAGE plpgsql SET search_path=provsql,pg_temp,public SECURITY DEFINER;

CREATE OR REPLACE FUNCTION remove_provenance(_tbl regclass)
  RETURNS void AS
$$
DECLARE
BEGIN
  EXECUTE format('ALTER TABLE %I DROP COLUMN provsql', _tbl);
  BEGIN
    EXECUTE format('DROP TRIGGER add_gate on %I', _tbl);
  EXCEPTION WHEN undefined_object THEN
  END;
END
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION repair_key(_tbl regclass, key_att text)
  RETURNS void AS
$$
DECLARE
  key RECORD;
  prefix_token uuid;
  inner_token uuid;
  times_token uuid;
  record RECORD;
  nb_rows INTEGER;
  ind INTEGER;
  remaining_prob DOUBLE PRECISION;
  select_key_att TEXT;
  where_condition TEXT;
BEGIN
  IF key_att = '' THEN
    key_att := '()';
    select_key_att := '1';
  ELSE
    select_key_att := key_att;
  END IF;

  EXECUTE format('ALTER TABLE %I ADD COLUMN provsql_temp provsql.provenance_token UNIQUE DEFAULT uuid_generate_v4()', _tbl);

  FOR key IN
    EXECUTE format('SELECT %s AS key FROM %I GROUP BY %s', select_key_att, _tbl, key_att)
  LOOP
    IF key_att = '()' THEN
      where_condition := '';
    ELSE
      where_condition := format('WHERE %s = %L', key_att, key.key);
    END IF;

    EXECUTE format('SELECT COUNT(*) FROM %I %s', _tbl, where_condition) INTO nb_rows;

    remaining_prob := 1;
    ind := 0;
    prefix_token = provsql.gate_one();
    FOR record IN
      EXECUTE format('SELECT provsql_temp FROM %I %s', _tbl, where_condition)
    LOOP
      IF ind < nb_rows - 1 THEN
        inner_token := uuid_generate_v4();
        PERFORM create_gate(inner_token, 'input');
        SELECT set_prob(inner_token, 1./nb_rows / remaining_prob);
        times_token := provsql.provenance_times(prefix_token, inner_token);
        remaining_prob = remaining_prob - 1./nb_rows;
        ind := ind + 1;
        prefix_token := provsql.provenance_monus(prefix_token, inner_token);
      ELSE
        times_token := prefix_token;  
      END IF;
      EXECUTE format('UPDATE %I SET provsql_temp = %L WHERE provsql_temp = %L', _tbl, times_token, record.provsql_temp);
    END LOOP;  
  END LOOP; 
  EXECUTE format('ALTER TABLE %I RENAME COLUMN provsql_temp TO provsql', _tbl);
  EXECUTE format('CREATE TRIGGER add_gate BEFORE INSERT ON %I FOR EACH ROW EXECUTE PROCEDURE provsql.add_gate_trigger()',_tbl);
END
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION create_provenance_mapping(newtbl text, oldtbl regclass, att text)
  RETURNS void AS
$$
DECLARE
BEGIN
  EXECUTE format('CREATE TEMP TABLE tmp_provsql ON COMMIT DROP AS TABLE %I', oldtbl);
  ALTER TABLE tmp_provsql RENAME provsql TO provenance;
  EXECUTE format('CREATE TABLE %I AS SELECT %s AS value, provenance FROM tmp_provsql', newtbl, att);
  EXECUTE format('CREATE INDEX ON %I(provenance)', newtbl);
END
$$ LANGUAGE plpgsql;

CREATE FUNCTION uuid_ns_provsql() RETURNS uuid AS
$$
 -- uuid_generate_v5(uuid_ns_url(),'http://pierre.senellart.com/software/provsql/')
 SELECT '920d4f02-8718-5319-9532-d4ab83a64489'::uuid
$$ LANGUAGE SQL IMMUTABLE;

CREATE FUNCTION gate_zero() RETURNS uuid AS
$$
  SELECT public.uuid_generate_v5(provsql.uuid_ns_provsql(),'zero');
$$ LANGUAGE SQL IMMUTABLE;
CREATE FUNCTION gate_one() RETURNS uuid AS
$$
  SELECT public.uuid_generate_v5(provsql.uuid_ns_provsql(),'one');
$$ LANGUAGE SQL IMMUTABLE;
      
CREATE FUNCTION uuid_provsql_concat(state uuid, token provenance_token)
  RETURNS provenance_token AS
$$
  SELECT
    CASE
    WHEN state IS NULL THEN
      token
    ELSE
      uuid_generate_v5(uuid_ns_provsql(),concat(state,token))::provenance_token
    END;
$$ LANGUAGE SQL IMMUTABLE SET search_path=provsql,public;

CREATE AGGREGATE uuid_provsql_agg(provenance_token) (
  SFUNC = uuid_provsql_concat,
  STYPE = provenance_token
);

CREATE FUNCTION provenance_times(VARIADIC tokens uuid[])
  RETURNS provenance_token AS
$$
DECLARE
  times_token uuid;
  filtered_tokens uuid[];
BEGIN
  SELECT array_agg(t) FROM unnest(tokens) t WHERE t <> gate_one() INTO filtered_tokens;

  CASE array_length(filtered_tokens,1)
    WHEN 0 THEN
      times_token:=gate_one();
    WHEN 1 THEN
      times_token:=filtered_tokens[1];
    ELSE
      SELECT uuid_generate_v5(uuid_ns_provsql(),concat('times',uuid_provsql_agg(t)))
      INTO times_token
      FROM unnest(filtered_tokens) t;

      PERFORM create_gate(times_token, 'times', filtered_tokens);
  END CASE;
  
  RETURN times_token;
END
$$ LANGUAGE plpgsql SET search_path=provsql,pg_temp,public SECURITY DEFINER;

CREATE FUNCTION provenance_monus(token1 provenance_token, token2 provenance_token)
  RETURNS provenance_token AS
$$
DECLARE
  monus_token uuid;
BEGIN
  IF token2 IS NULL THEN
    -- Special semantics, because of a LEFT OUTER JOIN used by the
    -- difference operator: token2 NULL means there is no second argument
    RETURN token1;
  END IF;

  IF token1 = token2 THEN
    -- X-X=0
    monus_token:=gate_zero();
  ELSIF token1 = gate_zero() THEN
    -- 0-X=0
    monus_token:=gate_zero();
  ELSIF token2 = gate_zero() THEN
    -- X-0=X
    monus_token:=token1;
  ELSE  
    monus_token:=uuid_generate_v5(uuid_ns_provsql(),concat('monus',token1,token2));
    PERFORM create_gate(monus_token, 'monus', ARRAY[token1, token2]);
  END IF;  

  RETURN monus_token;
END
$$ LANGUAGE plpgsql SET search_path=provsql,pg_temp,public SECURITY DEFINER;

CREATE FUNCTION provenance_project(token provenance_token, VARIADIC positions int[])
  RETURNS provenance_token AS
$$
DECLARE
  project_token uuid;
BEGIN
  project_token:=uuid_generate_v5(uuid_ns_provsql(),concat(token,positions));
  BEGIN
    LOCK TABLE provenance_circuit_extra;
    PERFORM create_gate(project_token, 'project', ARRAY[token]);
    INSERT INTO provenance_circuit_extra 
      SELECT gate, case when info=0 then null else info end, row_number() over()
      FROM (
             SELECT project_token gate, unnest(positions) info
           ) t; 
  EXCEPTION WHEN unique_violation THEN
  END;
  RETURN project_token;
END
$$ LANGUAGE plpgsql SET search_path=provsql,pg_temp,public SECURITY DEFINER;

CREATE FUNCTION provenance_eq(token provenance_token, pos1 int, pos2 int)
  RETURNS provenance_token AS
$$
DECLARE
  eq_token uuid;
BEGIN
  eq_token:=uuid_generate_v5(uuid_ns_provsql(),concat(token,pos1,pos2));
  LOCK TABLE provenance_circuit_extra;
  BEGIN
    PERFORM create_gate(eq_token, 'eq', ARRAY[token]);
    INSERT INTO provenance_circuit_extra SELECT eq_token, pos1, pos2;
  EXCEPTION WHEN unique_violation THEN
  END;
  RETURN eq_token;
END
$$ LANGUAGE plpgsql SET search_path=provsql,pg_temp,public SECURITY DEFINER; 

CREATE OR REPLACE FUNCTION provenance_plus(tokens uuid[])
  RETURNS provenance_token AS
$$
DECLARE
  c INTEGER;
  plus_token uuid;
  filtered_tokens uuid[];
BEGIN
  c:=array_length(tokens, 1);

  IF c = 0 THEN
    plus_token := gate_zero();
  ELSIF c = 1 THEN
    plus_token := tokens[1];
  ELSE
    SELECT array_agg(t)
    FROM (SELECT t from unnest(tokens) t ORDER BY t) tmp
    WHERE t <> gate_zero()
    INTO filtered_tokens;

    plus_token := uuid_generate_v5(
      uuid_ns_provsql(),
      concat('plus',array_to_string(filtered_tokens, ',')));

    PERFORM create_gate(plus_token, 'plus', filtered_tokens);
  END IF;

  RETURN plus_token;
END
$$ LANGUAGE plpgsql STRICT SET search_path=provsql,pg_temp,public SECURITY DEFINER;

CREATE OR REPLACE FUNCTION provenance_evaluate(
  token provenance_token,
  token2value regclass,
  element_one anyelement,
  value_type regtype,
  plus_function regproc,
  times_function regproc,
  monus_function regproc)
  RETURNS anyelement AS
$$
DECLARE
  gate_type provenance_gate;
  result ALIAS FOR $0;
BEGIN
  SELECT get_gate_type(token) INTO gate_type;
  
  IF gate_type IS NULL THEN
    RETURN NULL;
  ELSIF gate_type='input' THEN
    EXECUTE format('SELECT * FROM %I WHERE provenance=%L',token2value,token) INTO result;
    IF result IS NULL THEN
      result:=element_one;
    END IF;
  ELSIF gate_type='plus' THEN
    EXECUTE format('SELECT %I(provsql.provenance_evaluate(t,%L,%L::%s,%L,%L,%L,%L)) FROM unnest(get_children(%L)) AS t',
      plus_function,token2value,element_one,value_type,value_type,plus_function,times_function,monus_function,token)
    INTO result;
  ELSIF gate_type='times' THEN
    EXECUTE format('SELECT %I(provsql.provenance_evaluate(t,%L,%L::%s,%L,%L,%L,%L)) FROM unnest(get_children(%L)) AS t',
      times_function,token2value,element_one,value_type,value_type,plus_function,times_function,monus_function,token)
    INTO result;
  ELSIF gate_type='monus' THEN
    IF monus_function IS NULL THEN
      RAISE EXCEPTION USING MESSAGE='Provenance with negation evaluated over a semiring without monus function';
    ELSE
      EXECUTE format('SELECT %I(a[1],a[2]) FROM (SELECT array_agg(provsql.provenance_evaluate(t,%L,%L::%s,%L,%L,%L,%L)) AS a FROM unnest(get_children(%L)) AS t) tmp',
        monus_function,token2value,element_one,value_type,value_type,plus_function,times_function,monus_function,token)
      INTO result;
    END IF;
  ELSIF gate_type='eq' THEN
    EXECUTE format('SELECT provsql.provenance_evaluate((get_children(%L))[1],%L,%L::%s,%L,%L,%L,%L)',
      token,token2value,element_one,value_type,value_type,plus_function,times_function,monus_function)
    INTO result;
  ELSIF gate_type='zero' THEN
    EXECUTE format('SELECT %I(a) FROM (SELECT %L::%I AS a WHERE FALSE) temp',plus_function,element_one,value_type) INTO result;
  ELSIF gate_type='one' THEN
    EXECUTE format('SELECT %L::%I',element_one,value_type) INTO result;
  ELSIF gate_type='project' THEN
    EXECUTE format('SELECT provsql.provenance_evaluate((get_children(%L))[1],%L,%L::%s,%L,%L,%L,%L)',
      token,token2value,element_one,value_type,value_type,plus_function,times_function,monus_function)
    INTO result;
  ELSE
    RAISE EXCEPTION USING MESSAGE='Unknown gate type';
  END IF;
  RETURN result;
END
$$ LANGUAGE plpgsql;

/*
CREATE TYPE gate_with_prob AS (f UUID, t UUID, gate_type provenance_gate, prob DOUBLE PRECISION);
CREATE TYPE gate_with_desc AS (f UUID, t UUID, gate_type provenance_gate, desc_str CHARACTER VARYING, infos INTEGER[]);

CREATE OR REPLACE FUNCTION identify_token(
  token provenance_token, OUT table_name regclass, OUT nb_columns integer) AS
$$
DECLARE
  t RECORD;
  result RECORD;
BEGIN
  table_name:=NULL;
  nb_columns:=-1;
  FOR t IN
    SELECT relname, 
      (SELECT count(*) FROM pg_attribute a2 WHERE a2.attrelid=a1.attrelid AND attnum>0)-1 c
    FROM pg_attribute a1 JOIN pg_type ON atttypid=pg_type.oid
                        JOIN pg_namespace ns1 ON typnamespace=ns1.oid
                        JOIN pg_class ON attrelid=pg_class.oid
                        JOIN pg_namespace ns2 ON relnamespace=ns2.oid
    WHERE typname='provenance_token' AND relkind='r' 
                                     AND ns1.nspname='provsql' 
                                     AND ns2.nspname<>'provsql' 
                                     AND attname='provsql'
  LOOP
    EXECUTE format('SELECT * FROM %I WHERE provsql=%L',t.relname,token) INTO result;
    IF result IS NOT NULL THEN
      table_name:=t.relname;
      nb_columns:=t.c;
      EXIT;
    END IF;
  END LOOP;    
END
$$ LANGUAGE plpgsql STRICT;

CREATE OR REPLACE FUNCTION sub_circuit_for_where(token provenance_token)
  RETURNS TABLE(f provenance_token, t UUID, gate_type provenance_gate, table_name REGCLASS, nb_columns INTEGER, infos INTEGER[], tuple_no BIGINT) AS
$$
    WITH RECURSIVE transitive_closure(f,t,idx,gate_type) AS (
      SELECT f,t,idx,gate_type FROM provsql.provenance_circuit_wire JOIN provsql.provenance_circuit_gate ON gate=f WHERE f=$1
        UNION ALL
      SELECT DISTINCT p2.*,p3.gate_type FROM transitive_closure p1 JOIN provsql.provenance_circuit_wire p2 ON p1.t=p2.f JOIN provsql.provenance_circuit_gate p3 ON gate=p2.f
    ) SELECT t1.f, t1.t, t1.gate_type, table_name, nb_columns, infos, row_number() over() FROM (
      SELECT f, t::uuid, idx, gate_type, NULL AS table_name, NULL AS nb_columns FROM transitive_closure
      UNION ALL
        SELECT DISTINCT t, NULL::uuid, NULL::int, 'input'::provenance_gate, (id).table_name, (id).nb_columns FROM transitive_closure JOIN (SELECT t AS prov, provsql.identify_token(t) as id FROM transitive_closure WHERE t NOT IN (SELECT f FROM transitive_closure)) temp ON t=prov
      UNION ALL
        SELECT DISTINCT $1, NULL::uuid, NULL::int, 'input'::provenance_gate, (id).table_name, (id).nb_columns FROM (SELECT provsql.identify_token($1) AS id WHERE $1 NOT IN (SELECT f FROM transitive_closure)) temp
      ) t1 LEFT OUTER JOIN (
      SELECT gate, ARRAY_AGG(ARRAY[info1,info2]) infos FROM provenance_circuit_extra GROUP BY gate
    ) t2 ON t1.f=t2.gate ORDER BY f,idx
$$
LANGUAGE sql;

CREATE OR REPLACE FUNCTION sub_circuit(token provenance_token)
  RETURNS TABLE(f provenance_token, t UUID, gate_type provenance_gate) AS
$$
    WITH RECURSIVE transitive_closure(f,t,gate_type) AS (
      SELECT f,t,gate_type FROM provsql.provenance_circuit_wire JOIN provsql.provenance_circuit_gate ON gate=f WHERE f=$1
        UNION ALL
      SELECT DISTINCT p2.f, p2.t, p3.gate_type FROM transitive_closure p1 JOIN provsql.provenance_circuit_wire p2 ON p1.t=p2.f JOIN provsql.provenance_circuit_gate p3 ON gate=p2.f
    ) 
      SELECT f, t::uuid, gate_type FROM transitive_closure
      UNION ALL
        SELECT DISTINCT t, NULL::uuid, 'input'::provenance_gate FROM transitive_closure WHERE t NOT IN (SELECT f FROM transitive_closure)
      UNION ALL
        SELECT DISTINCT $1, NULL::uuid, 'input'::provenance_gate
$$
LANGUAGE sql;
*/

CREATE OR REPLACE FUNCTION provenance_evaluate(
  token provenance_token,
  token2value regclass,
  element_one anyelement,
  plus_function regproc,
  times_function regproc,
  monus_function regproc = NULL)
  RETURNS anyelement AS
  'provsql','provenance_evaluate' LANGUAGE C;

CREATE OR REPLACE FUNCTION probability_evaluate(
  token provenance_token,
  token2probability regclass,
  method text = NULL,
  arguments text = NULL)
  RETURNS DOUBLE PRECISION AS
  'provsql','probability_evaluate' LANGUAGE C;

CREATE OR REPLACE FUNCTION view_circuit(
  token provenance_token,
  token2desc regclass,
  dbg int = 0)
  RETURNS TEXT AS
  'provsql','view_circuit' LANGUAGE C;

CREATE OR REPLACE FUNCTION provenance() RETURNS provenance_token AS
 'provsql', 'provenance' LANGUAGE C;

CREATE OR REPLACE FUNCTION where_provenance(token provenance_token)
  RETURNS text AS
  'provsql','where_provenance' LANGUAGE C;

CREATE OR REPLACE FUNCTION initialize_constants() RETURNS void AS
  'provsql','initialize_constants' LANGUAGE C;

SELECT initialize_constants();

GRANT USAGE ON SCHEMA provsql TO PUBLIC;
GRANT SELECT ON provenance_circuit_extra TO PUBLIC;

SET search_path TO public;
