/* ------------------------------------------------------------------------
 *
 * range.sql
 *		RANGE partitioning functions
 *
 * Copyright (c) 2015-2016, Postgres Professional
 *
 * ------------------------------------------------------------------------
 */

CREATE OR REPLACE FUNCTION @extschema@.create_or_replace_sequence(
	parent_relid	REGCLASS,
	OUT seq_name	TEXT)
AS $$
BEGIN
	seq_name := @extschema@.build_sequence_name(parent_relid);

	EXECUTE format('DROP SEQUENCE IF EXISTS %s', seq_name);
	EXECUTE format('CREATE SEQUENCE %s START 1', seq_name);
END
$$
LANGUAGE plpgsql;

/*
 * Check RANGE partition boundaries.
 */
CREATE OR REPLACE FUNCTION @extschema@.check_boundaries(
	parent_relid	REGCLASS,
	expression		TEXT,
	start_value		ANYELEMENT,
	end_value		ANYELEMENT)
RETURNS VOID AS
$$
DECLARE
	v_min		start_value%TYPE;
	v_max		start_value%TYPE;
	v_count		BIGINT;

BEGIN
	/* Get min and max values */
	EXECUTE format('SELECT count(*), min(%1$s), max(%1$s)
					FROM %2$s WHERE NOT %1$s IS NULL',
				   expression, parent_relid::TEXT)
	INTO v_count, v_min, v_max;

	/* Check if column has NULL values */
	IF v_count > 0 AND (v_min IS NULL OR v_max IS NULL) THEN
		RAISE EXCEPTION 'expression "%" returns NULL values', expression;
	END IF;

	/* Check lower boundary */
	IF start_value > v_min THEN
		RAISE EXCEPTION 'start value is less than min value of "%"', expression;
	END IF;

	/* Check upper boundary */
	IF end_value <= v_max THEN
		RAISE EXCEPTION 'not enough partitions to fit all values of "%"', expression;
	END IF;
END
$$ LANGUAGE plpgsql;


CREATE OR REPLACE FUNCTION @extschema@.prepare_for_partitioning(
	parent_relid	REGCLASS,
	expression		TEXT,
	partition_data	BOOLEAN)
RETURNS VOID AS
$$
BEGIN
	PERFORM @extschema@.validate_relname(parent_relid);

	IF partition_data = true THEN
		/* Acquire data modification lock */
		PERFORM @extschema@.prevent_relation_modification(parent_relid);
	ELSE
		/* Acquire lock on parent */
		PERFORM @extschema@.lock_partitioned_relation(parent_relid);
	END IF;

	expression := lower(expression);
	PERFORM @extschema@.common_relation_checks(parent_relid, expression);
END
$$ LANGUAGE plpgsql;

/*
 * Creates RANGE partitions for specified relation based on datetime attribute
 */
CREATE OR REPLACE FUNCTION @extschema@.create_range_partitions(
	parent_relid	REGCLASS,
	expression		TEXT,
	start_value		ANYELEMENT,
	p_interval		INTERVAL,
	p_count			INTEGER DEFAULT NULL,
	partition_data	BOOLEAN DEFAULT TRUE)
RETURNS INTEGER AS
$$
DECLARE
	v_rows_count	BIGINT;
	v_atttype		REGTYPE;
	v_max			start_value%TYPE;
	v_cur_value		start_value%TYPE := start_value;
	end_value		start_value%TYPE;
	part_count		INTEGER := 0;
	i				INTEGER;

BEGIN
	expression := lower(expression);
	PERFORM @extschema@.prepare_for_partitioning(parent_relid, expression, partition_data);

	IF p_count < 0 THEN
		RAISE EXCEPTION '"p_count" must not be less than 0';
	END IF;

	/* Try to determine partitions count if not set */
	IF p_count IS NULL THEN
		EXECUTE format('SELECT count(*), max(%s) FROM %s', expression, parent_relid)
		INTO v_rows_count, v_max;

		IF v_rows_count = 0 THEN
			RAISE EXCEPTION 'cannot determine partitions count for empty table';
		END IF;

		p_count := 0;
		WHILE v_cur_value <= v_max
		LOOP
			v_cur_value := v_cur_value + p_interval;
			p_count := p_count + 1;
		END LOOP;
	END IF;

	v_atttype := @extschema@.get_base_type(pg_typeof(start_value));

	/*
	 * In case when user doesn't want to automatically create partitions
	 * and specifies partition count as 0 then do not check boundaries
	 */
	IF p_count != 0 THEN
		/* compute right bound of partitioning through additions */
		end_value := start_value;
		FOR i IN 1..p_count
		LOOP
			end_value := end_value + p_interval;
		END LOOP;

		/* Check boundaries */
		EXECUTE format('SELECT @extschema@.check_boundaries(''%s'', $1, ''%s'', ''%s''::%s)',
			   parent_relid,
			   start_value,
			   end_value,
			   v_atttype::TEXT)
		USING
				expression;
	END IF;

	/* Insert new entry to pathman config */
	PERFORM @extschema@.add_to_pathman_config(parent_relid, expression,
		p_interval::TEXT, false);

	/* Create sequence for child partitions names */
	PERFORM @extschema@.create_or_replace_sequence(parent_relid)
	FROM @extschema@.get_plain_schema_and_relname(parent_relid);

	IF p_count != 0 THEN
		part_count := @extschema@.create_range_partitions_internal(
									parent_relid,
									@extschema@.generate_range_bounds(start_value,
																	  p_interval,
																	  p_count),
									NULL,
									NULL);
	END IF;

	/* Notify backend about changes */
	PERFORM @extschema@.on_create_partitions(parent_relid);

	/* Relocate data if asked to */
	IF partition_data = true THEN
		PERFORM @extschema@.set_enable_parent(parent_relid, false);
		PERFORM @extschema@.partition_data(parent_relid);
	ELSE
		PERFORM @extschema@.set_enable_parent(parent_relid, true);
	END IF;

	RETURN part_count;
END
$$ LANGUAGE plpgsql;

/*
 * Creates RANGE partitions for specified relation based on numerical expression
 */
CREATE OR REPLACE FUNCTION @extschema@.create_range_partitions(
	parent_relid	REGCLASS,
	expression		TEXT,
	start_value		ANYELEMENT,
	p_interval		ANYELEMENT,
	p_count			INTEGER DEFAULT NULL,
	partition_data	BOOLEAN DEFAULT TRUE)
RETURNS INTEGER AS
$$
DECLARE
	v_rows_count	BIGINT;
	v_max			start_value%TYPE;
	v_cur_value		start_value%TYPE := start_value;
	end_value		start_value%TYPE;
	part_count		INTEGER := 0;
	i				INTEGER;

BEGIN
	expression := lower(expression);
	PERFORM @extschema@.prepare_for_partitioning(parent_relid, expression, partition_data);

	IF p_count < 0 THEN
		RAISE EXCEPTION 'partitions count must not be less than zero';
	END IF;

	/* Try to determine partitions count if not set */
	IF p_count IS NULL THEN
		EXECUTE format('SELECT count(*), max(%s) FROM %s', expression, parent_relid)
		INTO v_rows_count, v_max;

		IF v_rows_count = 0 THEN
			RAISE EXCEPTION 'cannot determine partitions count for empty table';
		END IF;

		IF v_max IS NULL THEN
			RAISE EXCEPTION 'expression "%" can return NULL values', expression;
		END IF;

		p_count := 0;
		WHILE v_cur_value <= v_max
		LOOP
			v_cur_value := v_cur_value + p_interval;
			p_count := p_count + 1;
		END LOOP;
	END IF;

	/*
	 * In case when user doesn't want to automatically create partitions
	 * and specifies partition count as 0 then do not check boundaries
	 */
	IF p_count != 0 THEN
		/* compute right bound of partitioning through additions */
		end_value := start_value;
		FOR i IN 1..p_count
		LOOP
			end_value := end_value + p_interval;
		END LOOP;

		/* check boundaries */
		PERFORM @extschema@.check_boundaries(parent_relid,
											 expression,
											 start_value,
											 end_value);
	END IF;

	/* Insert new entry to pathman config */
	PERFORM @extschema@.add_to_pathman_config(parent_relid, expression,
		p_interval::TEXT, false);

	/* Create sequence for child partitions names */
	PERFORM @extschema@.create_or_replace_sequence(parent_relid)
	FROM @extschema@.get_plain_schema_and_relname(parent_relid);

	IF p_count != 0 THEN
		part_count := @extschema@.create_range_partitions_internal(
						parent_relid,
						@extschema@.generate_range_bounds(start_value, p_interval, p_count),
						NULL,
						NULL);
	END IF;

	/* Notify backend about changes */
	PERFORM @extschema@.on_create_partitions(parent_relid);

	/* Relocate data if asked to */
	IF partition_data = true THEN
		PERFORM @extschema@.set_enable_parent(parent_relid, false);
		PERFORM @extschema@.partition_data(parent_relid);
	ELSE
		PERFORM @extschema@.set_enable_parent(parent_relid, true);
	END IF;

	RETURN p_count;
END
$$ LANGUAGE plpgsql;

/*
 * Creates RANGE partitions for specified relation based on bounds array
 */
CREATE OR REPLACE FUNCTION @extschema@.create_range_partitions(
	parent_relid	REGCLASS,
	expression		TEXT,
	bounds			ANYARRAY,
	partition_names	TEXT[] DEFAULT NULL,
	tablespaces		TEXT[] DEFAULT NULL,
	partition_data	BOOLEAN DEFAULT TRUE)
RETURNS INTEGER AS
$$
DECLARE
	part_count	INTEGER;
BEGIN
	IF array_ndims(bounds) > 1 THEN
		RAISE EXCEPTION 'Bounds array must be a one dimensional array';
	END IF;

	IF array_length(bounds, 1) < 2 THEN
		RAISE EXCEPTION 'Bounds array must have at least two values';
	END IF;

	expression := lower(expression);
	PERFORM @extschema@.prepare_for_partitioning(parent_relid, expression, partition_data);

	/* Check boundaries */
	PERFORM @extschema@.check_boundaries(parent_relid,
										 expression,
										 bounds[0],
										 bounds[array_length(bounds, 1) - 1]);

	/* Insert new entry to pathman config */
	PERFORM @extschema@.add_to_pathman_config(parent_relid, expression, NULL, false, 2);

	/* Create sequence for child partitions names */
	PERFORM @extschema@.create_or_replace_sequence(parent_relid)
	FROM @extschema@.get_plain_schema_and_relname(parent_relid);

	/* Create partitions */
	part_count := @extschema@.create_range_partitions_internal(parent_relid,
															   bounds,
															   partition_names,
															   tablespaces);

	/* Notify backend about changes */
	PERFORM @extschema@.on_create_partitions(parent_relid);

	/* Relocate data if asked to */
	IF partition_data = true THEN
		PERFORM @extschema@.set_enable_parent(parent_relid, false);
		PERFORM @extschema@.partition_data(parent_relid);
	ELSE
		PERFORM @extschema@.set_enable_parent(parent_relid, true);
	END IF;

	RETURN part_count;
END
$$
LANGUAGE plpgsql;

/*
 * Creates RANGE partitions for specified range
 */
CREATE OR REPLACE FUNCTION @extschema@.create_partitions_from_range(
	parent_relid	REGCLASS,
	expression		TEXT,
	start_value		ANYELEMENT,
	end_value		ANYELEMENT,
	p_interval		ANYELEMENT,
	partition_data	BOOLEAN DEFAULT TRUE)
RETURNS INTEGER AS
$$
DECLARE
	part_count		INTEGER := 0;

BEGIN
	expression := lower(expression);
	PERFORM @extschema@.prepare_for_partitioning(parent_relid, expression, partition_data);

	/* Check boundaries */
	PERFORM @extschema@.check_boundaries(parent_relid,
										 expression,
										 start_value,
										 end_value);

	/* Insert new entry to pathman config */
	PERFORM @extschema@.add_to_pathman_config(parent_relid, expression,
		p_interval::TEXT, false);

	/* Create sequence for child partitions names */
	PERFORM @extschema@.create_or_replace_sequence(parent_relid)
	FROM @extschema@.get_plain_schema_and_relname(parent_relid);

	WHILE start_value <= end_value
	LOOP
		PERFORM @extschema@.create_single_range_partition(
			parent_relid,
			start_value,
			start_value + p_interval,
			tablespace := @extschema@.get_tablespace(parent_relid));

		start_value := start_value + p_interval;
		part_count := part_count + 1;
	END LOOP;

	/* Notify backend about changes */
	PERFORM @extschema@.on_create_partitions(parent_relid);

	/* Relocate data if asked to */
	IF partition_data = true THEN
		PERFORM @extschema@.set_enable_parent(parent_relid, false);
		PERFORM @extschema@.partition_data(parent_relid);
	ELSE
		PERFORM @extschema@.set_enable_parent(parent_relid, true);
	END IF;

	RETURN part_count; /* number of created partitions */
END
$$ LANGUAGE plpgsql;

/*
 * Creates RANGE partitions for specified range based on datetime expression
 */
CREATE OR REPLACE FUNCTION @extschema@.create_partitions_from_range(
	parent_relid	REGCLASS,
	expression		TEXT,
	start_value		ANYELEMENT,
	end_value		ANYELEMENT,
	p_interval		INTERVAL,
	partition_data	BOOLEAN DEFAULT TRUE)
RETURNS INTEGER AS
$$
DECLARE
	part_count		INTEGER := 0;

BEGIN
	expression := lower(expression);
	PERFORM @extschema@.prepare_for_partitioning(parent_relid, expression,
		partition_data);

	/* Check boundaries */
	PERFORM @extschema@.check_boundaries(parent_relid,
										 expression,
										 start_value,
										 end_value);

	/* Insert new entry to pathman config */
	PERFORM @extschema@.add_to_pathman_config(parent_relid, expression,
		p_interval::TEXT, false);

	/* Create sequence for child partitions names */
	PERFORM @extschema@.create_or_replace_sequence(parent_relid)
	FROM @extschema@.get_plain_schema_and_relname(parent_relid);

	WHILE start_value <= end_value
	LOOP
		EXECUTE
			format('SELECT @extschema@.create_single_range_partition($1, $2, $3::%s, tablespace:=$4);',
				   @extschema@.get_base_type(pg_typeof(start_value))::TEXT)
		USING
			parent_relid,
			start_value,
			start_value + p_interval,
			@extschema@.get_tablespace(parent_relid);

		start_value := start_value + p_interval;
		part_count := part_count + 1;
	END LOOP;

	/* Notify backend about changes */
	PERFORM @extschema@.on_create_partitions(parent_relid);

	/* Relocate data if asked to */
	IF partition_data = true THEN
		PERFORM @extschema@.set_enable_parent(parent_relid, false);
		PERFORM @extschema@.partition_data(parent_relid);
	ELSE
		PERFORM @extschema@.set_enable_parent(parent_relid, true);
	END IF;

	RETURN part_count; /* number of created partitions */
END
$$ LANGUAGE plpgsql;


/*
 * Split RANGE partition
 */
CREATE OR REPLACE FUNCTION @extschema@.split_range_partition(
	partition_relid	REGCLASS,
	split_value		ANYELEMENT,
	partition_name	TEXT DEFAULT NULL,
	tablespace		TEXT DEFAULT NULL,
	OUT p_range		ANYARRAY)
RETURNS ANYARRAY AS
$$
DECLARE
	v_parent		REGCLASS;
	v_attname		TEXT;
	v_atttype		REGTYPE;
	v_cond			TEXT;
	v_new_partition	TEXT;
	v_part_type		INTEGER;
	v_check_name	TEXT;

BEGIN
	v_parent = @extschema@.get_parent_of_partition(partition_relid);

	/* Acquire lock on parent */
	PERFORM @extschema@.lock_partitioned_relation(v_parent);

	/* Acquire data modification lock (prevent further modifications) */
	PERFORM @extschema@.prevent_relation_modification(partition_relid);

	v_atttype = @extschema@.get_partition_key_type(v_parent);

	SELECT attname, parttype
	FROM @extschema@.pathman_config
	WHERE partrel = v_parent
	INTO v_attname, v_part_type;

	/* Check if this is a RANGE partition */
	IF v_part_type != 2 THEN
		RAISE EXCEPTION '"%" is not a RANGE partition', partition_relid::TEXT;
	END IF;

	/* Get partition values range */
	EXECUTE format('SELECT @extschema@.get_part_range($1, NULL::%s)',
				   @extschema@.get_base_type(v_atttype)::TEXT)
	USING partition_relid
	INTO p_range;

	IF p_range IS NULL THEN
		RAISE EXCEPTION 'could not find specified partition';
	END IF;

	/* Check if value fit into the range */
	IF p_range[1] > split_value OR p_range[2] <= split_value
	THEN
		RAISE EXCEPTION 'specified value does not fit into the range [%, %)',
			p_range[1], p_range[2];
	END IF;

	/* Create new partition */
	v_new_partition := @extschema@.create_single_range_partition(v_parent,
																 split_value,
																 p_range[2],
																 partition_name,
																 tablespace);

	/* Copy data */
	v_cond := @extschema@.build_range_condition(v_new_partition::regclass,
												v_attname, split_value, p_range[2]);
	EXECUTE format('WITH part_data AS (DELETE FROM %s WHERE %s RETURNING *)
					INSERT INTO %s SELECT * FROM part_data',
				   partition_relid::TEXT,
				   v_cond,
				   v_new_partition);

	/* Alter original partition */
	v_cond := @extschema@.build_range_condition(partition_relid::regclass,
												v_attname, p_range[1], split_value);
	v_check_name := @extschema@.build_check_constraint_name(partition_relid);

	EXECUTE format('ALTER TABLE %s DROP CONSTRAINT %s',
				   partition_relid::TEXT,
				   v_check_name);

	EXECUTE format('ALTER TABLE %s ADD CONSTRAINT %s CHECK (%s)',
				   partition_relid::TEXT,
				   v_check_name,
				   v_cond);

	/* Tell backend to reload configuration */
	PERFORM @extschema@.on_update_partitions(v_parent);
END
$$
LANGUAGE plpgsql;

/*
 * The special case of merging two partitions
 */
CREATE OR REPLACE FUNCTION @extschema@.merge_range_partitions(
	partition1		REGCLASS,
	partition2		REGCLASS)
RETURNS VOID AS
$$
BEGIN
	PERFORM @extschema@.merge_range_partitions(array[partition1, partition2]::regclass[]);
END
$$ LANGUAGE plpgsql;

/*
 * Append new partition.
 */
CREATE OR REPLACE FUNCTION @extschema@.append_range_partition(
	parent_relid	REGCLASS,
	partition_name	TEXT DEFAULT NULL,
	tablespace		TEXT DEFAULT NULL)
RETURNS TEXT AS
$$
DECLARE
	v_atttype		REGTYPE;
	v_part_name		TEXT;
	v_interval		TEXT;

BEGIN
	PERFORM @extschema@.validate_relname(parent_relid);

	/* Acquire lock on parent */
	PERFORM @extschema@.lock_partitioned_relation(parent_relid);

	v_atttype := @extschema@.get_partition_key_type(parent_relid);

	IF NOT @extschema@.is_date_type(v_atttype) AND
	   NOT @extschema@.is_operator_supported(v_atttype, '+') THEN
		RAISE EXCEPTION 'type % does not support ''+'' operator', v_atttype::REGTYPE;
	END IF;

	SELECT range_interval
	FROM @extschema@.pathman_config
	WHERE partrel = parent_relid
	INTO v_interval;

	EXECUTE
		format('SELECT @extschema@.append_partition_internal($1, $2, $3, ARRAY[]::%s[], $4, $5)',
			   @extschema@.get_base_type(v_atttype)::TEXT)
	USING
		parent_relid,
		v_atttype,
		v_interval,
		partition_name,
		tablespace
	INTO
		v_part_name;

	/* Invalidate cache */
	PERFORM @extschema@.on_update_partitions(parent_relid);
	RETURN v_part_name;
END
$$
LANGUAGE plpgsql;

/*
 * Spawn logic for append_partition(). We have to
 * separate this in order to pass the 'p_range'.
 *
 * NOTE: we don't take a xact_handling lock here.
 */
CREATE OR REPLACE FUNCTION @extschema@.append_partition_internal(
	parent_relid	REGCLASS,
	p_atttype		REGTYPE,
	p_interval		TEXT,
	p_range			ANYARRAY DEFAULT NULL,
	partition_name	TEXT DEFAULT NULL,
	tablespace		TEXT DEFAULT NULL)
RETURNS TEXT AS
$$
DECLARE
	v_part_name		TEXT;
	v_atttype		REGTYPE;
	v_args_format	TEXT;

BEGIN
	IF @extschema@.get_number_of_partitions(parent_relid) = 0 THEN
		RAISE EXCEPTION 'cannot append to empty partitions set';
	END IF;

	v_atttype := @extschema@.get_base_type(p_atttype);

	/* We have to pass fake NULL casted to column's type */
	EXECUTE format('SELECT @extschema@.get_part_range($1, -1, NULL::%s)',
				   v_atttype::TEXT)
	USING parent_relid
	INTO p_range;

	IF p_range[2] IS NULL THEN
		RAISE EXCEPTION 'Cannot append partition because last partition''s range is half open';
	END IF;

	IF @extschema@.is_date_type(p_atttype) THEN
		v_args_format := format('$1, $2, ($2 + $3::interval)::%s, $4, $5', v_atttype::TEXT);
	ELSE
		v_args_format := format('$1, $2, $2 + $3::%s, $4, $5', v_atttype::TEXT);
	END IF;

	EXECUTE
		format('SELECT @extschema@.create_single_range_partition(%s)', v_args_format)
	USING
		parent_relid,
		p_range[2],
		p_interval,
		partition_name,
		tablespace
	INTO
		v_part_name;

	RETURN v_part_name;
END
$$
LANGUAGE plpgsql;

/*
 * Prepend new partition.
 */
CREATE OR REPLACE FUNCTION @extschema@.prepend_range_partition(
	parent_relid	REGCLASS,
	partition_name	TEXT DEFAULT NULL,
	tablespace		TEXT DEFAULT NULL)
RETURNS TEXT AS
$$
DECLARE
	v_atttype		REGTYPE;
	v_part_name		TEXT;
	v_interval		TEXT;

BEGIN
	PERFORM @extschema@.validate_relname(parent_relid);

	/* Acquire lock on parent */
	PERFORM @extschema@.lock_partitioned_relation(parent_relid);

	v_atttype := @extschema@.get_partition_key_type(parent_relid);

	IF NOT @extschema@.is_date_type(v_atttype) AND
	   NOT @extschema@.is_operator_supported(v_atttype, '-') THEN
		RAISE EXCEPTION 'type % does not support ''-'' operator', v_atttype::REGTYPE;
	END IF;

	SELECT range_interval
	FROM @extschema@.pathman_config
	WHERE partrel = parent_relid
	INTO v_interval;

	EXECUTE
		format('SELECT @extschema@.prepend_partition_internal($1, $2, $3, ARRAY[]::%s[], $4, $5)',
			   @extschema@.get_base_type(v_atttype)::TEXT)
	USING
		parent_relid,
		v_atttype,
		v_interval,
		partition_name,
		tablespace
	INTO
		v_part_name;

	/* Invalidate cache */
	PERFORM @extschema@.on_update_partitions(parent_relid);
	RETURN v_part_name;
END
$$
LANGUAGE plpgsql;

/*
 * Spawn logic for prepend_partition(). We have to
 * separate this in order to pass the 'p_range'.
 *
 * NOTE: we don't take a xact_handling lock here.
 */
CREATE OR REPLACE FUNCTION @extschema@.prepend_partition_internal(
	parent_relid	REGCLASS,
	p_atttype		REGTYPE,
	p_interval		TEXT,
	p_range			ANYARRAY DEFAULT NULL,
	partition_name	TEXT DEFAULT NULL,
	tablespace		TEXT DEFAULT NULL)
RETURNS TEXT AS
$$
DECLARE
	v_part_name		TEXT;
	v_atttype		REGTYPE;
	v_args_format	TEXT;

BEGIN
	IF @extschema@.get_number_of_partitions(parent_relid) = 0 THEN
		RAISE EXCEPTION 'cannot prepend to empty partitions set';
	END IF;

	v_atttype := @extschema@.get_base_type(p_atttype);

	/* We have to pass fake NULL casted to column's type */
	EXECUTE format('SELECT @extschema@.get_part_range($1, 0, NULL::%s)',
				   v_atttype::TEXT)
	USING parent_relid
	INTO p_range;

	IF p_range[1] IS NULL THEN
		RAISE EXCEPTION 'Cannot prepend partition because first partition''s range is half open';
	END IF;

	IF @extschema@.is_date_type(p_atttype) THEN
		v_args_format := format('$1, ($2 - $3::interval)::%s, $2, $4, $5', v_atttype::TEXT);
	ELSE
		v_args_format := format('$1, $2 - $3::%s, $2, $4, $5', v_atttype::TEXT);
	END IF;

	EXECUTE
		format('SELECT @extschema@.create_single_range_partition(%s)', v_args_format)
	USING
		parent_relid,
		p_range[1],
		p_interval,
		partition_name,
		tablespace
	INTO
		v_part_name;

	RETURN v_part_name;
END
$$
LANGUAGE plpgsql;

/*
 * Add new partition
 */
CREATE OR REPLACE FUNCTION @extschema@.add_range_partition(
	parent_relid	REGCLASS,
	start_value		ANYELEMENT,
	end_value		ANYELEMENT,
	partition_name	TEXT DEFAULT NULL,
	tablespace		TEXT DEFAULT NULL)
RETURNS TEXT AS
$$
DECLARE
	v_part_name		TEXT;

BEGIN
	PERFORM @extschema@.validate_relname(parent_relid);

	/* Acquire lock on parent */
	PERFORM @extschema@.lock_partitioned_relation(parent_relid);

	IF start_value >= end_value THEN
		RAISE EXCEPTION 'failed to create partition: start_value is greater than end_value';
	END IF;

	/* check range overlap */
	IF @extschema@.get_number_of_partitions(parent_relid) > 0 THEN
		PERFORM @extschema@.check_range_available(parent_relid,
												  start_value,
												  end_value);
	END IF;

	/* Create new partition */
	v_part_name := @extschema@.create_single_range_partition(parent_relid,
															 start_value,
															 end_value,
															 partition_name,
															 tablespace);
	PERFORM @extschema@.on_update_partitions(parent_relid);

	RETURN v_part_name;
END
$$
LANGUAGE plpgsql;


/*
 * Drop range partition
 */
CREATE OR REPLACE FUNCTION @extschema@.drop_range_partition(
	partition_relid	REGCLASS,
	delete_data		BOOLEAN DEFAULT TRUE)
RETURNS TEXT AS
$$
DECLARE
	parent_relid	REGCLASS;
	part_name		TEXT;
	v_relkind		CHAR;
	v_rows			BIGINT;
	v_part_type		INTEGER;

BEGIN
	parent_relid := @extschema@.get_parent_of_partition(partition_relid);
	part_name := partition_relid::TEXT; /* save the name to be returned */

	SELECT parttype
	FROM @extschema@.pathman_config
	WHERE partrel = parent_relid
	INTO v_part_type;

	/* Check if this is a RANGE partition */
	IF v_part_type != 2 THEN
		RAISE EXCEPTION '"%" is not a RANGE partition', partition_relid::TEXT;
	END IF;

	/* Acquire lock on parent */
	PERFORM @extschema@.lock_partitioned_relation(parent_relid);

	IF NOT delete_data THEN
		EXECUTE format('INSERT INTO %s SELECT * FROM %s',
						parent_relid::TEXT,
						partition_relid::TEXT);
		GET DIAGNOSTICS v_rows = ROW_COUNT;

		/* Show number of copied rows */
		RAISE NOTICE '% rows copied from %', v_rows, partition_relid::TEXT;
	END IF;

	SELECT relkind FROM pg_catalog.pg_class
	WHERE oid = partition_relid
	INTO v_relkind;

	/*
	 * Determine the kind of child relation. It can be either regular
	 * table (r) or foreign table (f). Depending on relkind we use
	 * DROP TABLE or DROP FOREIGN TABLE.
	 */
	IF v_relkind = 'f' THEN
		EXECUTE format('DROP FOREIGN TABLE %s', partition_relid::TEXT);
	ELSE
		EXECUTE format('DROP TABLE %s', partition_relid::TEXT);
	END IF;

	/* Invalidate cache */
	PERFORM @extschema@.on_update_partitions(parent_relid);

	RETURN part_name;
END
$$
LANGUAGE plpgsql
SET pg_pathman.enable_partitionfilter = off; /* ensures that PartitionFilter is OFF */

/*
 * Attach range partition
 */
CREATE OR REPLACE FUNCTION @extschema@.attach_range_partition(
	parent_relid	REGCLASS,
	partition_relid	REGCLASS,
	start_value		ANYELEMENT,
	end_value		ANYELEMENT)
RETURNS TEXT AS
$$
DECLARE
	v_attname			TEXT;
	rel_persistence		CHAR;
	v_init_callback		REGPROCEDURE;

BEGIN
	PERFORM @extschema@.validate_relname(parent_relid);
	PERFORM @extschema@.validate_relname(partition_relid);

	/* Acquire lock on parent */
	PERFORM @extschema@.lock_partitioned_relation(parent_relid);

	/* Ignore temporary tables */
	SELECT relpersistence FROM pg_catalog.pg_class
	WHERE oid = partition_relid INTO rel_persistence;

	IF rel_persistence = 't'::CHAR THEN
		RAISE EXCEPTION 'temporary table "%" cannot be used as a partition',
						partition_relid::TEXT;
	END IF;

	/* check range overlap */
	PERFORM @extschema@.check_range_available(parent_relid, start_value, end_value);

	IF NOT @extschema@.is_tuple_convertible(parent_relid, partition_relid) THEN
		RAISE EXCEPTION 'partition must have a compatible tuple format';
	END IF;

	/* Set inheritance */
	EXECUTE format('ALTER TABLE %s INHERIT %s', partition_relid, parent_relid);

	v_attname := attname FROM @extschema@.pathman_config WHERE partrel = parent_relid;

	IF v_attname IS NULL THEN
		RAISE EXCEPTION 'table "%" is not partitioned', parent_relid::TEXT;
	END IF;

	/* Set check constraint */
	EXECUTE format('ALTER TABLE %s ADD CONSTRAINT %s CHECK (%s)',
				   partition_relid::TEXT,
				   @extschema@.build_check_constraint_name(partition_relid),
				   @extschema@.build_range_condition(partition_relid,
													 v_attname,
													 start_value,
													 end_value));

	/* Fetch init_callback from 'params' table */
	WITH stub_callback(stub) as (values (0))
	SELECT init_callback
	FROM stub_callback
	LEFT JOIN @extschema@.pathman_config_params AS params
	ON params.partrel = parent_relid
	INTO v_init_callback;

	/* If update trigger is enabled then create one for this partition */
	if @extschema@.has_update_trigger(parent_relid) THEN
		PERFORM @extschema@.create_single_update_trigger(parent_relid, partition_relid);
	END IF;

	/* Invoke an initialization callback */
	PERFORM @extschema@.invoke_on_partition_created_callback(parent_relid,
															 partition_relid,
															 v_init_callback,
															 start_value,
															 end_value);

	/* Invalidate cache */
	PERFORM @extschema@.on_update_partitions(parent_relid);

	RETURN partition_relid;
END
$$
LANGUAGE plpgsql;

/*
 * Detach range partition
 */
CREATE OR REPLACE FUNCTION @extschema@.detach_range_partition(
	partition_relid	REGCLASS)
RETURNS TEXT AS
$$
DECLARE
	v_attname		TEXT;
	parent_relid	REGCLASS;

BEGIN
	parent_relid := @extschema@.get_parent_of_partition(partition_relid);

	/* Acquire lock on parent */
	PERFORM @extschema@.prevent_relation_modification(parent_relid);

	v_attname := attname
	FROM @extschema@.pathman_config
	WHERE partrel = parent_relid;

	IF v_attname IS NULL THEN
		RAISE EXCEPTION 'table "%" is not partitioned', parent_relid::TEXT;
	END IF;

	/* Remove inheritance */
	EXECUTE format('ALTER TABLE %s NO INHERIT %s',
				   partition_relid::TEXT,
				   parent_relid::TEXT);

	/* Remove check constraint */
	EXECUTE format('ALTER TABLE %s DROP CONSTRAINT %s',
				   partition_relid::TEXT,
				   @extschema@.build_check_constraint_name(partition_relid));

	/* Remove update trigger */
	EXECUTE format('DROP TRIGGER IF EXISTS %s ON %s',
				   @extschema@.build_update_trigger_name(parent_relid),
				   partition_relid::TEXT);

	/* Invalidate cache */
	PERFORM @extschema@.on_update_partitions(parent_relid);

	RETURN partition_relid;
END
$$
LANGUAGE plpgsql;


/*
 * Merge multiple partitions. All data will be copied to the first one.
 * The rest of partitions will be dropped.
 */
CREATE OR REPLACE FUNCTION @extschema@.merge_range_partitions(
	partitions		REGCLASS[])
RETURNS VOID AS 'pg_pathman', 'merge_range_partitions'
LANGUAGE C STRICT;

/*
 * Drops partition and expands the next partition so that it cover dropped one
 *
 * This function was written in order to support Oracle-like ALTER TABLE ...
 * DROP PARTITION. In Oracle partitions only have upper bound and when
 * partition is dropped the next one automatically covers freed range
 */
CREATE OR REPLACE FUNCTION @extschema@.drop_range_partition_expand_next(
	partition_relid		REGCLASS)
RETURNS VOID AS 'pg_pathman', 'drop_range_partition_expand_next'
LANGUAGE C STRICT;


CREATE OR REPLACE FUNCTION @extschema@.create_range_partitions_internal(
	parent_relid	REGCLASS,
	bounds			ANYARRAY,
	partition_names	TEXT[],
	tablespaces		TEXT[])
RETURNS REGCLASS AS 'pg_pathman', 'create_range_partitions_internal'
LANGUAGE C;

/*
 * Creates new RANGE partition. Returns partition name.
 * NOTE: This function SHOULD NOT take xact_handling lock (BGWs in 9.5).
 */
CREATE OR REPLACE FUNCTION @extschema@.create_single_range_partition(
	parent_relid	REGCLASS,
	start_value		ANYELEMENT,
	end_value		ANYELEMENT,
	partition_name	TEXT DEFAULT NULL,
	tablespace		TEXT DEFAULT NULL)
RETURNS REGCLASS AS 'pg_pathman', 'create_single_range_partition_pl'
LANGUAGE C
SET client_min_messages = WARNING;

/*
 * Construct CHECK constraint condition for a range partition.
 */
CREATE OR REPLACE FUNCTION @extschema@.build_range_condition(
	partition_relid	REGCLASS,
	expression		TEXT,
	start_value		ANYELEMENT,
	end_value		ANYELEMENT)
RETURNS TEXT AS 'pg_pathman', 'build_range_condition'
LANGUAGE C;

CREATE OR REPLACE FUNCTION @extschema@.build_sequence_name(
	parent_relid	REGCLASS)
RETURNS TEXT AS 'pg_pathman', 'build_sequence_name'
LANGUAGE C STRICT;


/*
 * Returns N-th range (as an array of two elements).
 */
CREATE OR REPLACE FUNCTION @extschema@.get_part_range(
	parent_relid	REGCLASS,
	partition_idx	INTEGER,
	dummy			ANYELEMENT)
RETURNS ANYARRAY AS 'pg_pathman', 'get_part_range_by_idx'
LANGUAGE C;

/*
 * Returns min and max values for specified RANGE partition.
 */
CREATE OR REPLACE FUNCTION @extschema@.get_part_range(
	partition_relid	REGCLASS,
	dummy			ANYELEMENT)
RETURNS ANYARRAY AS 'pg_pathman', 'get_part_range_by_oid'
LANGUAGE C;

/*
 * Checks if range overlaps with existing partitions.
 * Returns TRUE if overlaps and FALSE otherwise.
 */
CREATE OR REPLACE FUNCTION @extschema@.check_range_available(
	parent_relid	REGCLASS,
	range_min		ANYELEMENT,
	range_max		ANYELEMENT)
RETURNS VOID AS 'pg_pathman', 'check_range_available_pl'
LANGUAGE C;

/*
 * Generate range bounds starting with 'p_start' using 'p_interval'.
 */
CREATE OR REPLACE FUNCTION @extschema@.generate_range_bounds(
	p_start			ANYELEMENT,
	p_interval		INTERVAL,
	p_count			INTEGER)
RETURNS ANYARRAY AS 'pg_pathman', 'generate_range_bounds_pl'
LANGUAGE C STRICT;

CREATE OR REPLACE FUNCTION @extschema@.generate_range_bounds(
	p_start			ANYELEMENT,
	p_interval		ANYELEMENT,
	p_count			INTEGER)
RETURNS ANYARRAY AS 'pg_pathman', 'generate_range_bounds_pl'
LANGUAGE C STRICT;
