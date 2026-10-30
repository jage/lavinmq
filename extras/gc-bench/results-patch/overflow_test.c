/* Exercises the patched branch of GC_signal_mark_stack_overflow directly: a push_other_roots
 * callback pushes a large region with GC_push_all_eager (as Crystal does for fiber stacks), which
 * overflows the global mark stack while the initiating thread pushes roots. Each root points to
 * a small object holding a pointer to a child; after every collection all objects are checked,
 * and garbage is allocated in between so a wrongly freed object would be reused and clobbered.
 * Usage: overflow_test [roots] [collections]   (GC_MARKERS / GC_PRINT_STATS from the env) */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#define GC_THREADS
#include <gc.h>
#include <gc/gc_mark.h>

#define MAGIC 0x5a5a5a5a5a5a5a5aUL

struct obj { struct obj *child; unsigned long magic; unsigned long id; };

static struct obj **roots; /* malloc'd, invisible to the GC except through the callback */
static size_t nroots;
static GC_push_other_roots_proc prev;

static void push_roots(void)
{
  if (prev) prev();
  GC_push_all_eager(roots, roots + nroots);
}

int main(int argc, char **argv)
{
  size_t i, c, bad = 0;
  int collections;
  nroots = argc > 1 ? strtoul(argv[1], NULL, 10) : 200000;
  collections = argc > 2 ? atoi(argv[2]) : 50;
  GC_INIT();
  GC_allow_register_threads(); /* starts the marker threads, as a first pthread_create would */
  roots = calloc(nroots, sizeof *roots);
  prev = GC_get_push_other_roots();
  GC_set_push_other_roots(push_roots);
  for (i = 0; i < nroots; i++) {
    struct obj *o = GC_MALLOC(sizeof *o), *ch = GC_MALLOC(sizeof *ch);
    ch->magic = MAGIC; ch->id = ~i; ch->child = NULL;
    o->magic = MAGIC; o->id = i; o->child = ch;
    roots[i] = o;
  }
  for (c = 0; c < (size_t)collections; c++) {
    for (i = 0; i < 100000; i++) {
      struct obj *g = GC_MALLOC(sizeof *g);
      memset(g, 0xff, sizeof *g);
    }
    GC_gcollect();
    for (i = 0; i < nroots; i++) {
      struct obj *o = roots[i];
      if (o->magic != MAGIC || o->id != i || !o->child || o->child->magic != MAGIC
          || o->child->id != ~i)
        bad++;
    }
  }
  printf("roots %zu collections %d helpers %d bad %zu %s\n", nroots, collections,
         GC_get_parallel(), bad, bad ? "FAIL" : "PASS");
  return bad ? 1 : 0;
}
