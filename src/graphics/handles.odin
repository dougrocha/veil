package graphics

import "../handles"

// The pool lives in its own package so the backend can use it too; these keep graphics call sites short.
Index :: handles.Index
Generation :: handles.Generation
Handle :: handles.Handle
Pool :: handles.Pool

pool_init :: handles.pool_init
pool_destroy :: handles.pool_destroy
pool_alloc :: handles.pool_alloc
pool_is_alive :: handles.pool_is_alive
pool_is_valid :: handles.pool_is_valid
pool_free :: handles.pool_free
pool_get :: handles.pool_get
