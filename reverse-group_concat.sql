###################
### THE PROBLEM ###
###################
# So, I will model this problem using CTE's(common table expressions), just like I implemented the solution.
# But consider that outside of this didatic example, the problem you will encounter in the wild is actually
# about real tables already populated with data, and you might not even have the permition or the option to
# redesign the involved tables.
#
# Let's say you have a table1 computed by:
#
with recursive table1(id_table1, whatever_data) as (
    select 1000, 'xxxx' union all
    select id_table1+1, 'xxxx' from table1 where id_table1+1 <= 1009
)
#
# which looks like this:
# select * from table1;
# output:
# id_table1    |        whatever_data
# ------------------------------------
# 1.000        |        xxxx
# 1.001        |        xxxx
# 1.002        |        xxxx
# 1.003        |        xxxx
# 1.004        |        xxxx
# 1.005        |        xxxx
# 1.006        |        xxxx
# 1.007        |        xxxx
# 1.008        |        xxxx
# 1.009        |        xxxx
#
# and another table is responsible for relating id_table1 to some other id, in a N:1 cardinality.
# You would expect this data to be normalized, something like:
#
, expected_table(id_table1, some_other_id) as (
    select 1000, 1 union
    select 1001, 2 union
    select 1002, 2 union
    select 1003, 3 union
    select 1004, 4 union
    select 1005, 4 union
    select 1006, 4 union
    select 1007, 4 union
    select 1008, 5 union
    select 1009, 5
)
# which would look like this:
# select * from expected_table;
# output:
# id_table1    |        some_other_id
# -----------------------------------
# 1.000        |        1
# 1.001        |        2
# 1.002        |        2
# 1.003        |        3
# 1.004        |        4
# 1.005        |        4
# 1.006        |        4
# 1.007        |        4
# 1.008        |        5
# 1.009        |        5
#
# But, to your surprise, this is what the data looks like:
#
, real_table(id_table1, some_other_id) as (
    select GROUP_CONCAT(id_table1 order by id_table1 separator ','), some_other_id
    from expected_table
    group by some_other_id
)
# select * from real_table;
# output:
# id_table1             |        some_other_id
# --------------------------------------------
# 1000                  |        1
# 1001,1002             |        2
# 1003                  |        3
# 1004,1005,1006,1007   |        4
# 1008,1009             |        5
#
# How to query information with a join between those tables? You could make up a weird
# join criteria using LIKE and CONCAT, but not only this is slower to compute than a
# simple key1 = key2, it also screws with the indexing.
# 
# Other solutions might be based on undoing the group_concat. My solution is one of those.
# As of the date I'm making this document, there's no built in function in mysql to reverse
# a group_concat operation, so I'll be explaining how to output the same result using CTE's.
# Unfortunately, it will not be viable for every possible context of this problem in the real
# world, as I can only attest to the performance of this method if you can actually create a
# table for temporary data, properly indexed, which will hold the id's for the 'real_table' in
# a normalized form.
#
####################
### THE SOLUTION ###
####################
# First, I make a CTE to measure the quantity of id's in each row of the grouped column.
# I did not create this LENGTH and REPLACE technique. I saw this way of measuring elements
# in a group_concat being used by multiple people on the internet and found it simple and
# elegant, so I took this method for myself ever since. It treats the string as an example
# of the fencepost problem. The number of posts is equal to adding 1 to the number of fences.
# As such, the number of elements in a group_concat is equal to the number of separators + 1 .
#
, measurement(concat_id, count_, some_other_id) as (
    select
        rt.id_table1,
        char_LENGTH(rt.id_table1) - char_LENGTH(REPLACE(rt.id_table1, ',', '')) + 1,
        rt.some_other_id
    from real_table rt
)
# select * from measurement;
# output:
# concat_id            |     count_      |    some_other_id
# ----------------------------------------------------------
# 1000                 |        1        |        1
# 1001,1002            |        2        |        2
# 1003                 |        1        |        3
# 1004,1005,1006,1007  |        4        |        4
# 1008,1009            |        2        |        5
#
# the next cte takes the output of the previous one and replicates each row by the count
# of elements in the group_concat, so that the cardinality of the table matches that of
# the expected result for each original row. For keeping track of the ordinal rank of each
# row without the need to calculate partitions, which can be quite slow, I make an extra
# column for the row number of current group.
#
,copy(concat_id, num, count_, some_other_id) as (
    select
        m.concat_id,
        1,
        m.count_,
        m.some_other_id
    from measurement m
    union all
    select
        copy.concat_id,
        copy.num + 1,
        copy.count_,
        copy.some_other_id
    from copy
    where copy.num+1 <= copy.count_
)
# select * from copy order by some_other_id;
# output:
# concat_id           |       num       |      count_     |   some_other_id
# -------------------------------------------------------------------------
# 1000                |        1        |        1        |        1
# 1001,1002           |        1        |        2        |        2
# 1001,1002           |        2        |        2        |        2
# 1003                |        1        |        1        |        3
# 1004,1005,1006,1007 |        1        |        4        |        4
# 1004,1005,1006,1007 |        2        |        4        |        4
# 1004,1005,1006,1007 |        3        |        4        |        4
# 1004,1005,1006,1007 |        4        |        4        |        4
# 1008,1009           |        1        |        2        |        5
# 1008,1009           |        2        |        2        |        5
#
# The next cte reduces the concat_id to only the substring correspondent to the
# single element of position equal to the num column. There are multiple ways of
# doing this. What I find most intuitive is using REGEXP_SUBSTR with 4 arguments.
# 
# ,reduce(concat_id, num, count_, single, some_other_id) as (
#     select
#         copy.concat_id,
#         copy.num,
#         copy.count_,
#         REGEXP_SUBSTR(
#             copy.concat_id,     # full string
#             '[^,]+',            # pattern
#             1,                  # start from character position 1
#             copy.num            # which occurrence number to return
#         ),
#         copy.some_other_id
#     from copy
# )
#
# although this REGEXP_SUBSTR might compute a little slow. Another problem is that
# some engines might have a different implementation of this function. MariaDB has
# an implementation of REGEXP_SUBSTR with only 2 arguments. So I prefer to use this
# other method, which works by shaving off the sides of the string outside of the
# substring extremities.
,reduce(concat_id, num, count_, single, some_other_id) as (
    select
        copy.concat_id,
        copy.num,
        copy.count_,
        replace(                                                                                    # this replace takes out the remaining separators from the result below
            replace(                                                                                # this one shaves off right side, past the right separator of the desired substring
                replace(copy.concat_id, SUBSTRING_INDEX(copy.concat_id, ',', copy.num-1), ''),      # and this shaves off left side, before the left separator of the desired substring
                SUBSTRING_INDEX(copy.concat_id, ',', - copy.count_ + copy.num), ''
            ),
            ',',''
        ),
        copy.some_other_id
    from copy
)
#
# both implementations are logically equivalent, and output the same result.
#
# select * from reduce order by some_other_id;
# output:
# concat_id           |       num       |      count_     |       single       |  some_other_id
# ---------------------------------------------------------------------------------------------
# 1000                |        1        |        1        |        1000        |        1
# 1001,1002           |        1        |        2        |        1001        |        2
# 1001,1002           |        2        |        2        |        1002        |        2
# 1003                |        1        |        1        |        1003        |        3
# 1004,1005,1006,1007 |        1        |        4        |        1004        |        4
# 1004,1005,1006,1007 |        2        |        4        |        1005        |        4
# 1004,1005,1006,1007 |        3        |        4        |        1006        |        4
# 1004,1005,1006,1007 |        4        |        4        |        1007        |        4
# 1008,1009           |        1        |        2        |        1008        |        5
# 1008,1009           |        2        |        2        |        1009        |        5
#
# So there you go, this is the end result. Some of the columns used for calculations are still shown
# just for the reader to see where each row of the previous cte's went to. The only thing you actually
# need is:
#
select
    r.single as id_table1,
    r.some_other_id
from reduce r;
#
# which ordering by [some_other_id, single] just to analyze more clearly, we can see that what
# we have at the end is the exact same table as the expected_table cte shown at the
# beginning:
#
# output:
# id_table1   |  some_other_id
# ----------------------------
# 1000        |        1
# 1001        |        2
# 1002        |        2
# 1003        |        3
# 1004        |        4
# 1005        |        4
# 1006        |        4
# 1007        |        4
# 1008        |        5
# 1009        |        5
